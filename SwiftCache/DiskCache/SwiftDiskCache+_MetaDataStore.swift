//
//  SwiftDiskCache+_MetaDataStore.swift
//  SwiftCache
//
//  Created by Zhu Shengqi on 15/03/2018.
//  Copyright © 2018 Zhu Shengqi. All rights reserved.
//

import Foundation

extension SwiftDiskCache {
  internal final class _MetaDataStore<Key: Hashable, Value> {
    
    private class Node {
      
      let key: Key
      let val: Value
      
      weak var pred: Node?
      weak var succ: Node?
      
      init(key: Key, val: Value) {
        self.key = key
        self.val = val
      }
      
    }
    
    private var keyNodeMap: [Key: Node] = [:]
    private var headNode: Node?
    private var tailNode: Node?
    
    internal subscript(_ key: Key) -> Value? {
      get {
        return keyNodeMap[key]?.val
      }
      set {
        if let existingNode = keyNodeMap[key] {
          _removeNode(existingNode)
        }
        
        if let value = newValue {
          let newNode = Node(key: key, val: value)
          _insertNode(newNode)
        }
      }
    }
    
    internal func removeObject(forKey key: Key) -> Value? {
      if let existingNode = keyNodeMap[key] {
        _removeNode(existingNode)
        return existingNode.val
      } else {
        return nil
      }
    }
    
    internal var isEmpty: Bool {
      assert((headNode == nil) == (tailNode == nil))
      return headNode == nil
    }
    
    internal func peekLastUsedValue() -> Value? {
      return tailNode?.val
    }
    
    internal func popLastUsed() -> Value? {
      guard let tail = tailNode else {
        return nil
      }
      
      _removeNode(tail)
      return tail.val
    }
    
    internal func hasValue(forKey key: Key) -> Bool {
      return keyNodeMap[key] != nil
    }
    
    private func _insertNode(_ node: Node) {
      assert(node.pred == nil)
      assert(node.succ == nil)
      
      keyNodeMap[node.key] = node
      
      node.succ = headNode
      headNode?.pred = node
      
      headNode = node
      if tailNode == nil {
        tailNode = node
      }
    }
    
    private func _removeNode(_ node: Node) {
      let pred = node.pred
      let succ = node.succ
      
      keyNodeMap[node.key] = nil
      
      pred?.succ = succ
      succ?.pred = pred
      
      if pred == nil {
        headNode = succ
      }
      if succ == nil {
        tailNode = pred
      }
    }
    
  }
}


