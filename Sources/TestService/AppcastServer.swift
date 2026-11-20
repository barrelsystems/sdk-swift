import Foundation

/// Sparkle's own appcast format: RSS/XML with `sparkle:`-namespaced
/// attributes. Hands back whatever XML a scenario configured, so
/// Sparkle's own real appcast-parsing code runs against it.
final class AppcastServer {
  private let server: MinimalHttpServer
  private let response: Locked<(status: Int, body: Data)> = Locked((204, Data()))

  init() {
    let response = response
    server = MinimalHttpServer { request in
      if request.path.hasPrefix("/update.zip") {
        return HttpResponse(status: 200, body: Data("fake update archive".utf8))
      }
      let current = response.read { $0 }
      return HttpResponse(status: current.status, body: current.body)
    }
  }

  @discardableResult
  func start() -> UInt16 {
    let port = server.start()
    Thread.detachNewThread { [server] in server.run() }
    return port
  }

  func setNextAppcastXML(_ xml: String) {
    response.write { $0 = (200, Data(xml.utf8)) }
  }

  func setNoUpdate() {
    response.write { $0 = (204, Data()) }
  }
}

/// A minimal, valid appcast item. `signature` is always blank here --
/// no scenario needs a genuinely-verified signature yet, since the
/// `available` state this feeds into is itself a known, documented gap.
func appcastXML(version: String, releaseNotes: String?, signature: String, feedBaseURL: String) -> String {
  let notesElement = releaseNotes.map { "<description><![CDATA[\($0)]]></description>" } ?? ""
  return """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <title>Version \(version)</title>
          \(notesElement)
          <sparkle:version>\(version)</sparkle:version>
          <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
          <enclosure url="\(feedBaseURL)/update.zip" sparkle:version="\(version)"
            sparkle:edSignature="\(signature)" length="20" type="application/octet-stream" />
        </item>
      </channel>
    </rss>
    """
}
