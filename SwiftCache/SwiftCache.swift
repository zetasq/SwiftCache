//
//  SwiftCache.swift
//  SwiftCache
//
//  Created by Zhu Shengqi on 17/03/2018.
//  Copyright © 2018 Zhu Shengqi. All rights reserved.
//

import Foundation

public final class SwiftCache<ObjectType> {
  
  // MARK: - Public properties
  public let cacheName: String
  
  // MARK: - Private properties
  private let memoryCache: SwiftMemoryCache<ObjectType>
  private let diskCache: SwiftDiskCache<ObjectType>
  
  // MARK: - Init & deinit
  public init(cacheName: String,
              memoryCacheCostLimit: Int,
              memoryCacheAgeLimit: TimeInterval,
              diskCacheParentDirectory: URL,
              diskCacheByteLimit: Int,
              diskCacheAgeLimit: TimeInterval,
              diskObjectEncoder: @escaping (ObjectType) throws -> Data,
              diskObjectDecoder: @escaping (Data) throws -> ObjectType) {
    self.cacheName = cacheName
    
    self.memoryCache = SwiftMemoryCache.init(cacheName: cacheName, costLimit: memoryCacheCostLimit, ageLimit: memoryCacheAgeLimit)
    self.diskCache = SwiftDiskCache(cacheParentDirectory: diskCacheParentDirectory, cacheName: cacheName, byteLimit: diskCacheByteLimit, ageLimit: diskCacheAgeLimit, objectEncoder: diskObjectEncoder, objectDecoder: diskObjectDecoder)
  }
  
  // MARK: - Public methods
  public func asyncCheckObjectCached(forKey key: String, completion: @escaping (Bool) -> Void) {
    if memoryCache.checkObjectCached(forKey: key) {
      completion(true)
    } else {
      self.diskCache.asyncCheckObjectCached(forKey: key) { cachedInDisk in
        completion(cachedInDisk)
      }
    }
  }
  
  public func asyncFetchObject(forKey key: String, completion: @escaping (ObjectType?) -> Void) {
    if let objectInMemory = memoryCache.fetchObject(forKey: key) {
      completion(objectInMemory)
    } else {
      self.diskCache.asyncFetchObject(forKey: key) { objectInDisk in
        completion(objectInDisk)
      }
    }
  }
  
  public func asyncRemoveObject(forKey key: String, completion: ((ObjectType?) -> Void)? = nil) {
    if let removedObjectInMemory = memoryCache.removeObject(forKey: key) {
      self.diskCache.asyncRemoveObject(forKey: key)
      completion?(removedObjectInMemory)
    } else {
      self.diskCache.asyncRemoveObject(forKey: key) { removedObjectInDisk in
        completion?(removedObjectInDisk)
      }
    }
  }
  
  public func asyncSetObject(_ object: ObjectType, forKey key: String, memoryCacheCost: Int = 0) {
    memoryCache.setObject(object, forKey: key, cost: memoryCacheCost)
    diskCache.asyncSetObject(object, forKey: key)
  }
  
  public func asyncTrimIfNeeded() {
    memoryCache.trimIfNeeded()
    diskCache.asyncTrimIfNeeded()
  }
  
  public func asyncClear() {
    memoryCache.clear()
    diskCache.asyncClear()
  }
  
}
