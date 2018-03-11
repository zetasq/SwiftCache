//
//  SwiftDiskCache.swift
//  SwiftCache
//
//  Created by Zhu Shengqi on 11/03/2018.
//  Copyright © 2018 Zhu Shengqi. All rights reserved.
//

import Foundation
import os.log

private let diskCacheLogger = OSLog(subsystem: "SwiftCache", category: "SwiftDiskCache")

private let safeFileNameCharacterSet = CharacterSet(charactersIn: ".:/%").inverted

private let fileNameEncoder: (String) -> String = { key in
  return key.addingPercentEncoding(withAllowedCharacters: safeFileNameCharacterSet)!
}

private let fileNameDecoder: (String) -> String = { fileName in
  return fileName.removingPercentEncoding!
}

public final class SwiftDiskCache<ObjectType: Codable> {

  // MARK: - Public properties
  public let cacheName: String
  public let cacheURL: URL
  
  public let byteLimit: Int
  public let ageLimit: TimeInterval
  
  // MARK: - Private properties
  private let _concurrentWorkQueue: DispatchQueue
    
  private let _trashSerialQueue: DispatchQueue
  private let _trashURL: URL
  
  private var _metaDataStore: _MetaDataStore<String, FileMetaData> = .init()

  private var _byteCount = 0
  
  // MARK: - Init & deinit
  public init(cacheParentDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!, cacheName: String, byteLimit: Int = 50 * 1024 * 1024, ageLimit: TimeInterval = 30 * 24 * 60 * 60) {
    assert(!cacheName.isEmpty)
    assert(byteLimit > 0)
    assert(ageLimit > 0)

    self.cacheName = cacheName
    self.cacheURL = cacheParentDirectory.appendingPathComponent(cacheName, isDirectory: true)
    self.byteLimit = byteLimit
    self.ageLimit = ageLimit
    
    self._concurrentWorkQueue = DispatchQueue(label: "SwiftDiskCache::\(cacheName).underlyingQueue", attributes: .concurrent)
    self._concurrentWorkQueue.setTarget(queue: .global(qos: .default))
    
    self._trashSerialQueue = DispatchQueue(label: "SwiftDiskCache::\(cacheName).trashQueue")
    self._trashSerialQueue.setTarget(queue: .global(qos: .background))
    self._trashURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    
    setup()
  }
  
  // MARK: - Cache setup
  private func setup() {
    _concurrentWorkQueue.suspend()
    _trashSerialQueue.suspend()
    
    let group = DispatchGroup()
    
    group.enter()
    DispatchQueue.global().async {
      self._locked_createCacheDirectory()
      self._locked_setupMetaData()
      group.leave()
    }
    
    group.enter()
    DispatchQueue.global().async {
      self._locked_createTrashDirectory()
      group.leave()
    }
    
    group.notify(queue: .global()) {
      self._locked_trimCacheIfNeeded()

      self._concurrentWorkQueue.resume()
      self._trashSerialQueue.resume()
    }
  }
  
  private func _locked_createCacheDirectory() {
    guard !FileManager.default.fileExists(atPath: self.cacheURL.path) else {
      return
    }
    
    do {
      try FileManager.default.createDirectory(at: self.cacheURL, withIntermediateDirectories: true, attributes: nil)
    } catch {
      os_log("%@", log: diskCacheLogger, type: .error, "Failed to create cacheURL: \(self.cacheURL), error: \(error)")
    }
  }
  
  private func _locked_setupMetaData() {
    do {
      let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
      let fileURLs = try FileManager.default.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: resourceKeys, options: .skipsHiddenFiles)
      
      var fileMetaDatas: [FileMetaData] = []
      
      for fileURL in fileURLs {
        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
        
        guard let modifiedDate = resourceValues.contentModificationDate, let fileSize = resourceValues.totalFileAllocatedSize else {
          continue
        }
        
        fileMetaDatas.append(FileMetaData(url: fileURL, modifiedDate: modifiedDate, fileSize: fileSize))
      }
      
      fileMetaDatas.sort(by: { $0.modifiedDate < $1.modifiedDate })
      
      for metaData in fileMetaDatas {
        let key = keyForCachedFileURL(metaData.url)

        guard !_metaDataStore.hasValue(forKey: key) else {
          continue
        }
        
        _metaDataStore[key] = metaData
        _byteCount += metaData.fileSize
      }
    } catch {
      os_log("%@", log: diskCacheLogger, type: .error, "Failed to read contents in cacheURL: \(self.cacheURL), error: \(error)")
    }
  }
  
  private func _locked_createTrashDirectory() {
    do {
      try FileManager.default.createDirectory(at: _trashURL, withIntermediateDirectories: true, attributes: nil)
    } catch {
      os_log("%@", log: diskCacheLogger, type: .error, "Failed to create sharedTrashURL: \(_trashURL), error: \(error)")
    }
  }
  
  
  // MARK: - Public methods
  public func asyncCheckCacheExists(forKey key: String, completion: @escaping (Bool) -> Void) {
    _concurrentWorkQueue.async {
      completion(self._metaDataStore.hasValue(forKey: key))
    }
  }
  
  public func asyncFetch(forKey key: String, completion: @escaping (ObjectType?) -> Void) {
    _concurrentWorkQueue.async {
      guard let fileMetaData = self._metaDataStore[key] else {
        completion(nil)
        return
      }
      
      // We don't extend the lifetime of the cached object now.
      
      //      defer {
      //        self._concurrentWorkQueue.async(flags: .barrier) {
      //          let newFileMetaData = FileMetaData(url: fileMetaData.url, modifiedDate: Date(), fileSize: fileMetaData.fileSize)
      //
      //          do {
      //            try FileManager.default.setAttributes([.modificationDate: newFileMetaData.modifiedDate], ofItemAtPath: newFileMetaData.url.path)
      //            self._storage[key] = newFileMetaData
      //          } catch {
      //            os_log("%@", log: diskCacheLogger, type: .error, "Failed to change modificationDate for url: \(newFileMetaData.url), error: \(error)")
      //          }
      //        }
      //      }
      
      do {
        let data = try Data(contentsOf: fileMetaData.url)
        let object = try JSONDecoder().decode(ObjectType.self, from: data)
        
        completion(object)
      } catch {
        completion(nil)
        os_log("%@", log: diskCacheLogger, type: .error, "Failed to decode object from url: \(fileMetaData.url), error: \(error)")
      }
    }
  }
  
  public func asyncRemoveObject(forKey key: String) {
    _concurrentWorkQueue.async(flags: .barrier) {
      if let existingFileMetaData = self._metaDataStore.removeObject(forKey: key) {
        self._locked_moveCachedFileToTrash(fileURL: existingFileMetaData.url)
        self._byteCount -= existingFileMetaData.fileSize
        self._clearTrash()
      }
    }
  }
  
  public func asyncSet(_ object: ObjectType, forKey key: String) {
    _concurrentWorkQueue.async(flags: .barrier) {
      if let existingFileMetaData = self._metaDataStore.removeObject(forKey: key) {
        self._locked_moveCachedFileToTrash(fileURL: existingFileMetaData.url)
        self._byteCount -= existingFileMetaData.fileSize
        self._clearTrash()
      }
      
      do {
        let data = try JSONEncoder().encode(object)
        let fileURL = self.cachedFileURLForKey(key)
        
        do {
          try data.write(to: fileURL)
          
          do {
            let resourceValues = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey])
            
            guard let modifiedDate = resourceValues.contentModificationDate, let fileSize = resourceValues.totalFileAllocatedSize else {
              os_log("%@", log: diskCacheLogger, type: .error, "Failed to read contentModificationDate and totalFileAllocatedSize from url: \(fileURL)")
              try? FileManager.default.removeItem(at: fileURL) // prevent the cache directory is inconsistent with metaDataStore
              return
            }
            self._metaDataStore[key] = FileMetaData(url: fileURL, modifiedDate: modifiedDate, fileSize: fileSize)
            self._byteCount += fileSize
          } catch {
            os_log("%@", log: diskCacheLogger, type: .error, "Failed to get resource values from url: \(fileURL), error: \(error)")
          }
        } catch {
          os_log("%@", log: diskCacheLogger, type: .error, "Failed to write encoded object: \(object), to url: \(fileURL), error: \(error)")
        }
      } catch {
        os_log("%@", log: diskCacheLogger, type: .error, "Failed to encode object: \(object), error: \(error)")
      }
    }
  }
  
  func asyncTrimCacheIfNeeded() {
    _concurrentWorkQueue.async(flags: .barrier) {
      self._locked_trimCacheIfNeeded()
    }
  }
  
  func asyncClearCache() {
    _concurrentWorkQueue.async(flags: .barrier) {
      while let existingFileMetaData = self._metaDataStore.popLastUsed() {
        self._locked_moveCachedFileToTrash(fileURL: existingFileMetaData.url)
      }
      self._byteCount = 0
      self._clearTrash()
    }
  }
  
  // MARK: - Helper methods
  private func _locked_trimCacheIfNeeded() {
    let now = Date()
    
    while !_metaDataStore.isEmpty && (_byteCount > byteLimit || now.timeIntervalSince(_metaDataStore.peekLastUsedValue()!.modifiedDate) > ageLimit) {
      let fileMetaData = _metaDataStore.popLastUsed()!
      _byteCount -= fileMetaData.fileSize
      
      _locked_moveCachedFileToTrash(fileURL: fileMetaData.url)
    }
    
    _clearTrash()
  }
  
  private func keyForCachedFileURL(_ url: URL) -> String {
    let fileName = url.lastPathComponent
    return fileNameDecoder(fileName)
  }
  
  private func cachedFileURLForKey(_ key: String) -> URL {
    assert(!key.isEmpty)
    
    return cacheURL.appendingPathComponent(fileNameEncoder(key), isDirectory: false)
  }
  
  private func _locked_moveCachedFileToTrash(fileURL: URL) {
    let fileName = fileURL.lastPathComponent
    let targetURL = self._trashURL.appendingPathComponent(fileName, isDirectory: false)
    
    try? FileManager.default.linkItem(at: fileURL, to: targetURL) // We don't catch error because file may exist at targetURL

    do {
      try FileManager.default.removeItem(at: fileURL)
    } catch {
      os_log("%@", log: diskCacheLogger, type: .error, "Failed to remove file at \(fileURL), error: \(error)")
    }
  }
    
  private func _clearTrash() {
    _trashSerialQueue.async {
      do {
        let fileURLs = try FileManager.default.contentsOfDirectory(at: self._trashURL, includingPropertiesForKeys: nil, options: [])
        
        for url in fileURLs {
          do {
            try FileManager.default.removeItem(at: url)
          } catch {
            os_log("%@", log: diskCacheLogger, type: .error, "Failed to remove file in trash: \(url), error: \(error)")
          }
        }
      } catch {
        os_log("%@", log: diskCacheLogger, type: .error, "Failed to fetch contents of trash directory: \(self._trashURL), error: \(error)")
      }
    }
  }

}

// MARK: - CustomStringConvertible
extension SwiftDiskCache: CustomStringConvertible {
  
  public var description: String {
    return "SwiftDiskCache: name = \(cacheName), url = \(cacheURL)"
  }
  
}
