# SwiftCache

A light-weight caching framework in Swift

[![Carthage Compatible](https://img.shields.io/badge/Carthage-compatible-4BC51D.svg?style=flat)](https://github.com/Carthage/Carthage)

## Installation
### Carthage
To integrate **SwiftCache** into your Xcode project using [Carthage](https://github.com/Carthage/Carthage), specify it in your `Cartfile`:

```ogdl
github "zetasq/SwiftCache"
```

Run `carthage update` to build the framework. Drag the built `SwiftCache.framework` into your Xcode project.

## Usage

You can use either `SwiftMemoryCache` to have a memory cache, or `SwiftDiskCache` to have a disk cache. You can also use `SwiftCache` to combine a memory cache and disk cache.

```swift

// Memory cache
let memoryCache = SwiftMemoryCache<Data>(
  cacheName: "dataMemoryCache",
  costLimit: 100 * 1024 * 1024,
  ageLimit: 30 * 24 * 60 * 60
)

let objectForMemoryCache: Data = ... // create data object
memoryCache.setObject(objectForMemoryCache, forKey: "key-for-data-in-memory", cost: objectForMemoryCache.count) // save data

let cachedDataInMemory = memoryCache.fetchObject(forKey: "key-for-data-in-memory") // retrieve cached data

// Disk cache
let diskCache = SwiftDiskCache<Data>(
  cacheName: "diskCache",
  byteLimit: 100 * 1024 * 1024,
  ageLimit: 30 * 24 * 60 * 60,
  objectEncoder: { $0 }, 
  objectDecoder: { $0 }
)

let objectForDiskCache: Data = ... // create data object
diskCache.asyncSetObject(objectForDiskCache, forKey: "key-for-data-on-disk") // save data

diskCache.asyncFetchObject(forKey: "key-for-data-on-disk") { cachedDataOnDisk in
  // do something with the data object
}

```

## License

**SwiftCache** is released under the MIT license. [See LICENSE](https://github.com/zetasq/SwiftCache/blob/master/LICENSE) for details.
