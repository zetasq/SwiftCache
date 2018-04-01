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

public final class SwiftDiskCache<ObjectType> {

  // MARK: - Public properties
  public let cacheName: String
  public let cacheURL: URL
  
  public let byteLimit: Int
  public let ageLimit: TimeInterval
  
  // MARK: - Private properties
  private let objectEncoder: (ObjectType) throws -> Data
  private let objectDecoder: (Data) throws -> ObjectType
  
  private let _concurrentWorkQueue: DispatchQueue
    
  private let _trashSerialQueue: DispatchQueue
  private let _trashURL: URL
  
  private var _cacheEntryStore: _CacheEntryStore<String, CacheEntry> = .init()

  private var _byteCount = 0
  
  // MARK: - Init & deinit
  public init(cacheParentDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!,
              cacheName: String,
              byteLimit: Int = 50 * 1024 * 1024,
              ageLimit: TimeInterval = 30 * 24 * 60 * 60,
              objectEncoder: @escaping (ObjectType) throws -> Data,
              objectDecoder: @escaping (Data) throws -> ObjectType) {
    
    assert(!cacheName.isEmpty)
    assert(byteLimit > 0)
    assert(ageLimit > 0)

    self.cacheName = cacheName
    self.cacheURL = cacheParentDirectory.appendingPathComponent(cacheName, isDirectory: true)
    self.byteLimit = byteLimit
    self.ageLimit = ageLimit
    
    self.objectEncoder = objectEncoder
    self.objectDecoder = objectDecoder
    
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
      self._locked_setupCacheEntries()
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
  
  private func _locked_setupCacheEntries() {
    do {
      let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
      let fileURLs = try FileManager.default.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: resourceKeys, options: .skipsHiddenFiles)
      
      var cacheEntries: [CacheEntry] = []
      
      for fileURL in fileURLs {
        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
        
        guard let modifiedDate = resourceValues.contentModificationDate, let fileSize = resourceValues.totalFileAllocatedSize else {
          continue
        }
        
        cacheEntries.append(CacheEntry(url: fileURL, modifiedDate: modifiedDate, fileSize: fileSize))
      }
      
      cacheEntries.sort(by: { $0.modifiedDate < $1.modifiedDate })
      
      for entry in cacheEntries {
        let key = keyForCachedFileURL(entry.url)

        guard !_cacheEntryStore.containsValue(forKey: key) else {
          continue
        }
        
        _cacheEntryStore[key] = entry
        _byteCount += entry.fileSize
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
  public func asyncCheckObjectCached(forKey key: String, completion: @escaping (Bool) -> Void) {
    _concurrentWorkQueue.async {
      completion(self._cacheEntryStore.containsValue(forKey: key))
    }
  }
  
  public func asyncFetchObject(forKey key: String, completion: @escaping (ObjectType?) -> Void) {
    _concurrentWorkQueue.async {
      guard let entry = self._cacheEntryStore[key] else {
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
        let data = try Data(contentsOf: entry.url, options: .mappedIfSafe)
        let object = try self.objectDecoder(data)
        
        completion(object)
      } catch {
        completion(nil)
        os_log("%@", log: diskCacheLogger, type: .error, "Failed to decode object from url: \(entry.url), error: \(error)")
      }
    }
  }
  
  public func asyncRemoveObject(forKey key: String, completion: ((ObjectType?) -> Void)? = nil) {
    _concurrentWorkQueue.async(flags: .barrier) {
      guard let existingEntry = self._cacheEntryStore.removeObject(forKey: key) else {
        completion?(nil)
        return
      }
      
      defer {
        self._locked_moveCachedFileToTrash(fileURL: existingEntry.url)
        self._byteCount -= existingEntry.fileSize
        self._clearTrash()
      }
      
      guard let completion = completion else {
        return
      }
      
      do {
        let data = try Data(contentsOf: existingEntry.url)
        let object = try self.objectDecoder(data)
        completion(object)
      } catch {
        os_log("%@", log: diskCacheLogger, type: .error, "Failed to decode object from url: \(existingEntry.url), error: \(error)")
        completion(nil)
      }
    }
  }
  
  public func asyncSetObject(_ object: ObjectType, forKey key: String) {
    _concurrentWorkQueue.async(flags: .barrier) {
      if let existingEntry = self._cacheEntryStore.removeObject(forKey: key) {
        self._locked_moveCachedFileToTrash(fileURL: existingEntry.url)
        self._byteCount -= existingEntry.fileSize
        self._clearTrash()
      }
      
      do {
        let data = try self.objectEncoder(object)
        let fileURL = self.cachedFileURLForKey(key)
        
        do {
          try data.write(to: fileURL)
          
          do {
            let resourceValues = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey])
            
            guard let modifiedDate = resourceValues.contentModificationDate, let fileSize = resourceValues.totalFileAllocatedSize else {
              os_log("%@", log: diskCacheLogger, type: .error, "Failed to read contentModificationDate and totalFileAllocatedSize from url: \(fileURL)")
              try? FileManager.default.removeItem(at: fileURL) // prevent the cache directory is inconsistent with cacheEntryStore
              return
            }
            self._cacheEntryStore[key] = CacheEntry(url: fileURL, modifiedDate: modifiedDate, fileSize: fileSize)
            self._byteCount += fileSize
            self._locked_trimCacheIfNeeded()
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
  
  func asyncTrimIfNeeded() {
    _concurrentWorkQueue.async(flags: .barrier) {
      self._locked_trimCacheIfNeeded()
    }
  }
  
  func asyncClear() {
    _concurrentWorkQueue.async(flags: .barrier) {
      while let entry = self._cacheEntryStore.popLast() {
        self._locked_moveCachedFileToTrash(fileURL: entry.url)
      }
      self._byteCount = 0
      self._clearTrash()
    }
  }
  
  // MARK: - Helper methods
  private func _locked_trimCacheIfNeeded() {
    let now = Date()
    
    let needsTrimCondition = {
      return !self._cacheEntryStore.isEmpty && (self._byteCount > self.byteLimit || now.timeIntervalSince(self._cacheEntryStore.peekLastValue()!.modifiedDate) > self.ageLimit)
    }
    
    guard needsTrimCondition() else {
      return
    }
    
    repeat {
      let entry = _cacheEntryStore.popLast()!
      _byteCount -= entry.fileSize
      
      _locked_moveCachedFileToTrash(fileURL: entry.url)
    } while needsTrimCondition()
    
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
