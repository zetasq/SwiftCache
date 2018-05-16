//
//  SwiftMemoryCache.swift
//  SwiftCache
//
//  Created by Zhu Shengqi on 17/03/2018.
//  Copyright © 2018 Zhu Shengqi. All rights reserved.
//

import Foundation

public final class SwiftMemoryCache<ObjectType> {
  
  // MARK: - Public properties
  public let cacheName: String
  
  public let costLimit: Int
  public let ageLimit: TimeInterval
  
  // MARK: - Private properties
  private var _lock = os_unfair_lock_s()

  private var _totalCost: Int = 0
  
  private var _cacheEntryStore: _CacheEntryStore<String, CacheEntry> = .init()
  
  // MARK: - Init & deinit
  public init(cacheName: String,
              costLimit: Int = .max,
              ageLimit: TimeInterval = .greatestFiniteMagnitude) {
    self.cacheName = cacheName
    self.costLimit = costLimit
    self.ageLimit = ageLimit
    
    NotificationCenter.default.addObserver(self, selector: #selector(self.applicationDidEnterBackground(_:)), name: .UIApplicationDidEnterBackground, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(self.applicationDidReceiveMemoryWarning(_:)), name: .UIApplicationDidReceiveMemoryWarning, object: nil)
  }
  
  // MARK: - Public methods
  public func checkObjectCached(forKey key: String) -> Bool {
    os_unfair_lock_lock(&_lock)
    defer {
      os_unfair_lock_unlock(&_lock)
    }
    
    return _cacheEntryStore.containsValue(forKey: key)
  }
  
  public func fetchObject(forKey key: String) -> ObjectType? {
    os_unfair_lock_lock(&_lock)
    defer {
      os_unfair_lock_unlock(&_lock)
    }
    
    return _cacheEntryStore[key]?.object
  }
  
  @discardableResult
  public func removeObject(forKey key: String) -> ObjectType? {
    os_unfair_lock_lock(&_lock)
    defer {
      os_unfair_lock_unlock(&_lock)
    }
    
    if let entry = _cacheEntryStore.removeObject(forKey: key) {
      _totalCost -= entry.cost
      return entry.object
    } else {
      return nil
    }
  }
  
  public func setObject(_ object: ObjectType, forKey key: String, cost: Int = 0) {
    os_unfair_lock_lock(&_lock)
    defer {
      os_unfair_lock_unlock(&_lock)
    }
    
    if let existingEntry = _cacheEntryStore.removeObject(forKey: key) {
      _totalCost -= existingEntry.cost
    }
    
    let entry = CacheEntry(object: object, modifiedDate: Date(), cost: cost)
    _cacheEntryStore[key] = entry
    _totalCost += cost
    
    _locked_trimIfNeeded()
  }
  
  public func trimIfNeeded() {
    os_unfair_lock_lock(&_lock)
    defer {
      os_unfair_lock_unlock(&_lock)
    }
    
    _locked_trimIfNeeded()
  }
  
  
  public func clear() {
    os_unfair_lock_lock(&_lock)
    defer {
      os_unfair_lock_unlock(&_lock)
    }
    
    _cacheEntryStore.removeAll()
    _totalCost = 0
  }
  
  // MARK: - Private methods
  private func _locked_trimIfNeeded() {
    let now = Date()
    
    while !_cacheEntryStore.isEmpty && (_totalCost > costLimit || now.timeIntervalSince(_cacheEntryStore.peekLastValue()!.modifiedDate) > ageLimit) {
      let entry = _cacheEntryStore.popLast()!
      _totalCost -= entry.cost
    }
  }
  
  // MARK: - Notification handlers
  @objc
  private func applicationDidEnterBackground(_ notification: Notification) {
    clear()
  }
  
  @objc
  private func applicationDidReceiveMemoryWarning(_ notification: Notification) {
    clear()
  }
  
}
