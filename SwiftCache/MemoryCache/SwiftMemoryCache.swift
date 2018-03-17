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
  private let lock = NSLock()

  private var _totalCost: Int = 0
  
  private var _cacheEntryStore: _CacheEntryStore<String, CacheEntry> = .init()
  
  // MARK: - Init & deinit
  public init(cacheName: String, costLimit: Int = .max, ageLimit: TimeInterval = .greatestFiniteMagnitude) {
    self.cacheName = cacheName
    self.costLimit = costLimit
    self.ageLimit = ageLimit
    
    NotificationCenter.default.addObserver(self, selector: #selector(self.applicationDidEnterBackground(_:)), name: .UIApplicationDidEnterBackground, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(self.applicationDidReceiveMemoryWarning(_:)), name: .UIApplicationDidReceiveMemoryWarning, object: nil)
  }
  
  // MARK: - Public methods
  public func asyncCheckObjectCached(forKey key: String, completion: @escaping (Bool) -> Void) {
    DispatchQueue.global().async {
      completion(self.syncCheckObjectCached(forKey: key))
    }
  }
  
  public func syncCheckObjectCached(forKey key: String) -> Bool {
    lock.lock()
    defer {
      lock.unlock()
    }
    
    return _cacheEntryStore.containsValue(forKey: key)
  }
  
  public func asyncFetchObject(forKey key: String, completion: @escaping (ObjectType?) -> Void) {
    DispatchQueue.global().async {
      completion(self.syncFetchObject(forKey: key))
    }
  }
  
  public func syncFetchObject(forKey key: String) -> ObjectType? {
    lock.lock()
    defer {
      lock.unlock()
    }
    
    return _cacheEntryStore[key]?.object
  }
  
  public func asyncRemoveObject(forKey key: String, completion: ((ObjectType?) -> Void)? = nil) {
    DispatchQueue.global().async {
      let object = self.syncRemoveObject(forKey: key)
      completion?(object)
    }
  }
  
  @discardableResult
  public func syncRemoveObject(forKey key: String) -> ObjectType? {
    lock.lock()
    defer {
      lock.unlock()
    }
    
    if let entry = _cacheEntryStore.removeObject(forKey: key) {
      _totalCost -= entry.cost
      return entry.object
    } else {
      return nil
    }
  }
  
  public func asyncSetObject(_ object: ObjectType, forKey key: String, cost: Int = 0) {
    DispatchQueue.global().async {
      self.syncSetObject(object, forKey: key, cost: cost)
    }
  }
  
  public func syncSetObject(_ object: ObjectType, forKey key: String, cost: Int = 0) {
    lock.lock()
    defer {
      lock.unlock()
    }
    
    if let existingEntry = _cacheEntryStore.removeObject(forKey: key) {
      _totalCost -= existingEntry.cost
    }
    
    let entry = CacheEntry(object: object, modifiedDate: Date(), cost: cost)
    _cacheEntryStore[key] = entry
    _totalCost += cost
    
    _locked_trimIfNeeded()
  }
  
  public func asyncTrimIfNeeded() {
    DispatchQueue.global().async {
      self.lock.lock()
      defer {
        self.lock.unlock()
      }
      
      self._locked_trimIfNeeded()
    }
  }
  
  public func syncTrimIfNeeded() {
    lock.lock()
    defer {
      lock.unlock()
    }
    
    _locked_trimIfNeeded()
  }
  
  public func asyncClear() {
    DispatchQueue.global().async {
      self.syncClear()
    }
  }
  
  public func syncClear() {
    lock.lock()
    defer {
      lock.unlock()
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
    asyncClear()
  }
  
  @objc
  private func applicationDidReceiveMemoryWarning(_ notification: Notification) {
    asyncClear()
  }
  
}
