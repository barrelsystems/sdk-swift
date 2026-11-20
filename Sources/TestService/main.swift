import Foundation

setvbuf(stdout, nil, _IOLBF, 0)  // a piped stdout defaults to full buffering; the harness reads this port line
let server = MinimalHttpServer { request in route(request) }
let port = server.start()
print("swift test-service listening on http://localhost:\(port)")
Thread.detachNewThread { server.run() }
RunLoop.main.run()
