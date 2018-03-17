//
//  SwiftDiskCache+FileMetaData.swift
//  SwiftCache
//
//  Created by Zhu Shengqi on 15/03/2018.
//  Copyright © 2018 Zhu Shengqi. All rights reserved.
//

import Foundation

extension SwiftDiskCache {
  
  internal struct CacheEntry {
    
    internal let url: URL
    
    internal let modifiedDate: Date
    
    internal let fileSize: Int
    
  }
  
}
