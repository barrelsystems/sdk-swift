import Foundation

@testable import BarrelKit

enum BufferPersistenceMode: String {
  case normal, blocked, failed
}

final class BufferWriteGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var blocked = false
  private var waiting = false
  private var currentMode = BufferPersistenceMode.normal

  var mode: BufferPersistenceMode {
    get {
      condition.lock()
      defer { condition.unlock() }
      return currentMode
    }
    set {
      condition.lock()
      currentMode = newValue
      condition.unlock()
    }
  }

  func beforeWrite() {
    condition.lock()
    defer { condition.unlock() }

    while blocked {
      waiting = true
      condition.wait()
    }

    waiting = false
  }

  func block() {
    condition.lock()
    blocked = true
    condition.unlock()
  }

  func release() {
    condition.lock()
    blocked = false
    condition.broadcast()
    condition.unlock()
  }

  var blockedWrite: Bool {
    condition.lock()
    defer { condition.unlock() }
    return waiting
  }
}

final class BufferPersistenceControls: @unchecked Sendable {
  private let lock = NSLock()
  private var gates: [String: BufferWriteGate] = [:]

  func gate(for path: String) -> BufferWriteGate {
    lock.withLock {
      if let gate = gates[path] { return gate }

      let gate = BufferWriteGate()
      gates[path] = gate
      return gate
    }
  }
}

let bufferPersistenceControls = BufferPersistenceControls()

func installBufferPersistenceControl() {
  #if DEBUG
    PersistenceWriter.setBeforeQueuedWrite { path in
      bufferPersistenceControls.gate(for: path).beforeWrite()
    }
  #endif
}

func setBufferPersistence(path: String, mode: BufferPersistenceMode) async {
  let gate = bufferPersistenceControls.gate(for: path)
  gate.release()
  await PersistenceWriter.waitForPendingWrites()

  if gate.mode == .failed { try? FileManager.default.removeItem(atPath: path) }
  if mode == .failed {
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }

  gate.mode = mode
  if mode == .blocked { gate.block() }
}
