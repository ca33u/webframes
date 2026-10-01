import Foundation
import Testing
@testable import Web_Frames

@Suite("Frame URL policy") struct FrameURLPolicyTests {
    @Test func onlyWebAndGitHubSourcesLoad() {
        #expect(FrameURLPolicy.allowedURL("http://localhost:3000/settings") != nil)
        #expect(FrameURLPolicy.allowedURL("https://example.com") != nil)
        #expect(FrameURLPolicy.allowedURL("wf-github://owner/repo/index.html") != nil)
        for blocked in ["file:///etc/passwd", "wf-local://123/index.html", "javascript:alert(1)",
                        "data:text/html,<b>x</b>", "x-apple.systempreferences:", "http://", "garbage"] {
            #expect(FrameURLPolicy.allowedURL(blocked) == nil, "\(blocked)")
        }
    }

    @Test func browserGetsOnlyWebPages() {
        #expect(FrameURLPolicy.browserURL("https://example.com") != nil)
        #expect(FrameURLPolicy.browserURL("wf-github://owner/repo") == nil)
        #expect(FrameURLPolicy.browserURL("file:///Applications") == nil)
    }

    @Test func placeholderEscapesTheSource() {
        let html = FrameURLPolicy.unsupportedHTML(for: "file:///<script>")
        #expect(html.contains("&lt;script&gt;"))
        #expect(!html.contains("<script>"))
    }

    @Test func remoteAddressesAreNotLocal() {
        #expect(LocalServerDiscovery.isLocal("http://127.0.0.1:5173"))
        #expect(!LocalServerDiscovery.isLocal("https://tracker.example"))
    }
}

@Suite("GitHub API URLs") struct GitHubAPITests {
    @Test func namesAreValidatedInsteadOfCrashing() {
        #expect(GitHubAPI.isValidName("acme-co") && GitHubAPI.isValidName("site.io"))
        for bad in ["", "a b", "../x", "..", "owner/repo", "ümlaut"] { #expect(!GitHubAPI.isValidName(bad), "\(bad)") }
    }

    @Test func pathsAreEscapedByURLComponents() {
        let url = GitHubAPI.url(path: ["repos", "acme", "site", "git", "trees", "feature/new nav"],
                                query: [URLQueryItem(name: "recursive", value: "1")])
        #expect(url?.absoluteString == "https://api.github.com/repos/acme/site/git/trees/feature/new%20nav?recursive=1")
    }
}
