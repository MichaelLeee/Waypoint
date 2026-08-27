//
//  UnsafePointer+bridge.swift
//  Waypoint
//

func bridge<T: AnyObject>(obj: T) -> UnsafeMutableRawPointer {
    return UnsafeMutableRawPointer(Unmanaged.passUnretained(obj).toOpaque())
}

func bridge<T: AnyObject>(ptr: UnsafeRawPointer) -> T {
    return Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()
}
