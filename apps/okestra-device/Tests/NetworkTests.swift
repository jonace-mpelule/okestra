import Network
import XCTest

@testable import DeviceTransport

final class NetworkTests: XCTestCase {
  func testFragmentedReadsAndCancellation() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    let queue = DispatchQueue(label: "okestra.socket.test")
    let ready = DispatchSemaphore(value: 0)
    var peer: NWConnection?
    listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
    listener.newConnectionHandler = { connection in
      peer = connection
      connection.start(queue: queue)
      connection.send(
        content: Data([1]),
        completion: .contentProcessed { _ in
          queue.asyncAfter(deadline: .now() + 0.05) {
            connection.send(content: Data([2, 3]), completion: .contentProcessed { _ in })
          }
        })
    }
    listener.start(queue: queue)
    XCTAssertEqual(ready.wait(timeout: .now() + 3), .success)
    let port = try XCTUnwrap(listener.port)
    let socket = DeviceSocket(port: port.rawValue)
    defer {
      socket.close()
      peer?.cancel()
      listener.cancel()
    }
    try socket.start()
    XCTAssertEqual(try socket.read(3, timeout: 2), Data([1, 2, 3]))
    let stopped = expectation(description: "blocked read cancelled")
    DispatchQueue.global().async {
      do {
        _ = try socket.read(12)
        XCTFail("Read succeeded after cancellation")
      } catch {}
      stopped.fulfill()
    }
    socket.close()
    wait(for: [stopped], timeout: 3)
  }
}
