import Foundation

installBufferPersistenceControl()

if let config = ProcessInfo.processInfo.environment["BARREL_BUFFER_PROBE"],
  let data = config.data(using: .utf8),
  let probe = try? JSONDecoder().decode(BufferExitProbe.self, from: data)
{
  Task { await runBufferExitProbe(probe) }
  RunLoop.main.run()
  exit(1)
}

// a piped stdout defaults to full buffering; the harness reads this port line
setvbuf(stdout, nil, _IOLBF, 0)
let server = MinimalHttpServer { request in route(request) }
let port = server.start()
print("swift test-service listening on http://localhost:\(port)")
Thread.detachNewThread { server.run() }
RunLoop.main.run()
