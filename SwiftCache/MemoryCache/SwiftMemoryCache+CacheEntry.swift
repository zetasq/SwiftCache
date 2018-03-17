//
//  SwiftMemoryCache+CacheEntry.swift
//  SwiftCache
//
//  Created by Zhu Shengqi on 17/03/2018.
//  Copyright © 2018 Zhu Shengqi. All rights reserved.
//

import Foundation

extension SwiftMemoryCache {
  
  internal struct CacheEntry {
    
    internal let object: ObjectType
    
    internal let modifiedDate: Date
    
    internal let cost: Int
    
  }
  
}
