// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

class FIFOStack<T> {
    private var elements: [T?]
    private var head: Int = 0
    private var tail: Int = 0
    private var capacity: Int
    private var size: Int = 0
    
    // Initialize with specified capacity
    init(capacity: Int) {
        self.capacity = max(1, capacity) // Minimum capacity is 1
        self.elements = [T?](repeating: nil, count: capacity)
    }
    
    // Add an element to the end of the queue
    @discardableResult
    func push(_ element: T) -> Bool {
        elements[tail] = element
        tail = (tail + 1) % capacity
        if size < capacity {
            size += 1
        } else {
            // If the queue is full, advance head to overwrite the oldest element (front)
            head = (head + 1) % capacity
        }
        return true
    }
    
    // Remove and return the first element
    func pop() -> T? {
        guard size > 0 else { return nil } // Check for an empty queue
        let frontIndex = head
        let element = elements[frontIndex]
        elements[frontIndex] = nil
        head = (head + 1) % capacity
        size -= 1
        return element
    }
    
    // Get the first element without removing it
    var top: T? {
        return size > 0 ? elements[head] : nil
    }
    
    // Check if the queue is empty
    var isEmpty: Bool {
        return size == 0
    }
    
    // Check if the queue is full
    var isFull: Bool {
        return size == capacity
    }
    
    // Current number of elements
    var count: Int {
        return size
    }
    
    // Clear the queue
    func clear() {
        elements = [T?](repeating: nil, count: capacity)
        head = 0
        tail = 0
        size = 0
    }
}
