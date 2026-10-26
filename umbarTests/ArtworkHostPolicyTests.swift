//
//  ArtworkHostPolicyTests.swift
//  umbarTests
//
//  Card #41: only https artwork from Spotify's CDNs is fetched.
//

import Foundation
import Testing

@Suite("ArtworkHostPolicy")
struct ArtworkHostPolicyTests {
    @Test(arguments: [
        "https://i.scdn.co/image/ab67616d0000b273",
        "HTTPS://I.SCDN.CO/x",
        "https://mosaic.spotifycdn.com/x",
    ])
    func allowsSpotifyCDNOverHTTPS(_ string: String) throws {
        #expect(ArtworkHostPolicy.allows(try #require(URL(string: string))))
    }

    @Test(arguments: [
        "http://i.scdn.co/x",               // not https
        "ftp://i.scdn.co/x",                // not https
        "file:///etc/passwd",               // no host
        "https://evilscdn.co/x",            // suffix without a dot boundary
        "https://i.scdn.co.evil.com/x",     // allowed name as a subdomain
        "https://i.scdn.co@evil.com/x",     // allowed name as userinfo
        "https://evil.com/?h=i.scdn.co",    // allowed name in the query
        "https://example.com/a.png",
        "https://is1-ssl.mzstatic.com/x",   // Apple Music artwork comes as bytes, not URLs
        "https://xn--scdn-co.evil/x",       // punycode look-alike
    ])
    func rejectsEverythingElse(_ string: String) throws {
        #expect(!ArtworkHostPolicy.allows(try #require(URL(string: string))))
    }
}
