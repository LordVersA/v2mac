import Foundation

/// Real-shaped share links, one per scheme and transport.
enum Fixtures {
    static let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
    static let realityKey = "jmsHqm9I9NJN3d3cZmhU6iM3sFM0q9D9p1tBvXkQm2E"
    static let sha = "4b363bd924df5bf09f87bd445755ff8e5742b9a8a0480cda261061416c3c7dce"
    static let wgPrivate = "yAnz5TF%2BlXXJte14tji3zlMNq%2Bhd2rYUIgJBgB3fBmk%3D"
    static let wgPublic = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg%3D"

    static func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
    static func b64url(_ s: String) -> String {
        b64(s).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func vmessJSON(_ json: String) -> String { "vmess://" + b64(json) }

    static let vlessRealityVision =
        "vless://\(uuid)@srv.example.com:443?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=www.microsoft.com&fp=chrome&pbk=\(realityKey)&sid=ab12&spx=%2F#Reality%20Vision"
    static let vlessWS =
        "vless://\(uuid)@cdn.example.com:443?type=ws&security=tls&sni=cdn.example.com&fp=chrome&alpn=h2%2Chttp%2F1.1&path=%2Fws%3Fed%3D2048&host=cdn.example.com#WS%20TLS"
    static let vlessGRPC =
        "vless://\(uuid)@srv.example.com:443?type=grpc&security=tls&serviceName=svc&mode=multi&sni=a.example.com#gRPC"
    static let vlessXHTTP =
        "vless://\(uuid)@srv.example.com:443?type=xhttp&security=reality&sni=www.microsoft.com&fp=firefox&pbk=\(realityKey)&sid=&path=%2Fx&host=h.example.com&mode=auto&extra=%7B%22xPaddingBytes%22%3A%22100-1000%22%7D#XHTTP"
    static let vlessSplitHTTP =
        "vless://\(uuid)@srv.example.com:443?type=splithttp&security=tls&sni=a.example.com&path=%2Fs#Split"
    static let vlessHTTPUpgrade =
        "vless://\(uuid)@srv.example.com:443?type=httpupgrade&security=tls&sni=a.example.com&path=%2Fu&host=h.example.com#HU"
    static let vlessRawHTTP =
        "vless://\(uuid)@srv.example.com:443?type=tcp&headerType=http&host=a.example.com&path=%2F&security=tls&sni=a.example.com#RawHTTP"
    static let vlessIPv6 =
        "vless://\(uuid)@[2001:db8::1]:443?security=tls&sni=a.example.com#IPv6"
    static let vlessEmojiName =
        "vless://\(uuid)@srv.example.com:443?security=tls&sni=a.example.com#🇩🇪 Frankfurt | 01"
    static let vlessNoName =
        "vless://\(uuid)@srv.example.com:443?security=tls&sni=a.example.com"
    static let vlessPinned =
        "vless://\(uuid)@srv.example.com:443?security=tls&sni=a.example.com&pcs=\(sha)&vcn=a.example.com#Pinned"
    static let vlessInsecure =
        "vless://\(uuid)@srv.example.com:443?security=tls&sni=a.example.com&allowInsecure=1#Insecure"
    static let vlessECH =
        "vless://\(uuid)@srv.example.com:443?security=tls&sni=a.example.com&ech=AEX%2BDQBB#ECH"

    static let vmessWS = vmessJSON(#"{"v":"2","ps":"VMess WS","add":"srv.example.com","port":"443","id":"\#(uuid)","aid":"0","scy":"auto","net":"ws","type":"none","host":"cdn.example.com","path":"/vm","tls":"tls","sni":"cdn.example.com","alpn":"h2,http/1.1","fp":"chrome"}"#)
    static let vmessGRPC = vmessJSON(#"{"v":"2","ps":"VMess gRPC","add":"srv.example.com","port":443,"id":"\#(uuid)","aid":0,"scy":"auto","net":"grpc","type":"multi","host":"","path":"svc","tls":"tls","sni":"a.example.com"}"#)
    static let vmessTCPHTTP = vmessJSON(#"{"v":"2","ps":"VMess HTTP","add":"1.2.3.4","port":"80","id":"\#(uuid)","aid":"0","scy":"auto","net":"tcp","type":"http","host":"a.example.com","path":"/","tls":""}"#)
    static let vmessKCP = vmessJSON(#"{"v":"2","ps":"VMess KCP","add":"1.2.3.4","port":"4000","id":"\#(uuid)","aid":"0","scy":"auto","net":"kcp","type":"srtp","host":"","path":"seedval","tls":""}"#)
    static let vmessURL =
        "vmess://\(uuid)@srv.example.com:443?type=ws&security=tls&sni=a.example.com&path=%2Fv&host=a.example.com&encryption=zero#VMess%20URL"

    static let trojanWS =
        "trojan://p%40ss@srv.example.com:443?sni=a.example.com&type=ws&path=%2Ft&host=a.example.com#Trojan%20WS"
    static let trojanPlain = "trojan://pw@1.2.3.4:443#Trojan"

    static var ssSIP002: String { "ss://\(b64url("aes-256-gcm:pa55word"))@1.2.3.4:8388#SS%20SIP002" }
    static let ss2022 =
        "ss://2022-blake3-aes-128-gcm:MTIzNDU2Nzg5MDEyMzQ1Ng%3D%3D@1.2.3.4:8388#SS2022"
    static var ssLegacy: String { "ss://\(b64("aes-256-gcm:pa55word@1.2.3.4:8388"))#SS%20Legacy" }

    static let hy2 = "hysteria2://pw@srv.example.com:443/?sni=a.example.com#HY2"
    static let hy2Hop =
        "hy2://pw@srv.example.com:443,5000-6000/?sni=a.example.com&obfs=salamander&obfs-password=ob&alpn=h3#HY2%20Hop"
    static let hy2Insecure = "hysteria2://pw@srv.example.com:443/?sni=a.example.com&insecure=1#HY2%20Insecure"

    static var socksB64: String { "socks://\(b64("user:pass"))@1.2.3.4:1080#Socks" }
    static let socksPlain = "socks5://user:pass@1.2.3.4:1080#Socks5"
    static let socksNoAuth = "socks://1.2.3.4:1080"
    static let httpProxy = "http://u:p@1.2.3.4:8080#HTTP"
    static let httpsProxy = "https://u:p@proxy.example.com:443#HTTPS"

    static let wireguard =
        "wireguard://\(wgPrivate)@1.2.3.4:51820?publickey=\(wgPublic)&address=10.0.0.2%2F32%2Cfd00%3A%3A2&mtu=1280&reserved=1%2C2%2C3#WG"

    /// Every link here must parse and produce an outbound that `xray run -test` accepts.
    static var valid: [(name: String, link: String)] {
        [
            ("vlessRealityVision", vlessRealityVision), ("vlessWS", vlessWS), ("vlessGRPC", vlessGRPC),
            ("vlessXHTTP", vlessXHTTP), ("vlessSplitHTTP", vlessSplitHTTP), ("vlessHTTPUpgrade", vlessHTTPUpgrade),
            ("vlessRawHTTP", vlessRawHTTP), ("vlessIPv6", vlessIPv6), ("vlessEmojiName", vlessEmojiName),
            ("vlessNoName", vlessNoName), ("vlessPinned", vlessPinned), ("vlessInsecure", vlessInsecure),
            ("vlessECH", vlessECH),
            ("vmessWS", vmessWS), ("vmessGRPC", vmessGRPC), ("vmessTCPHTTP", vmessTCPHTTP),
            ("vmessKCP", vmessKCP), ("vmessURL", vmessURL),
            ("trojanWS", trojanWS), ("trojanPlain", trojanPlain),
            ("ssSIP002", ssSIP002), ("ss2022", ss2022), ("ssLegacy", ssLegacy),
            ("hy2", hy2), ("hy2Hop", hy2Hop), ("hy2Insecure", hy2Insecure),
            ("socksB64", socksB64), ("socksPlain", socksPlain), ("socksNoAuth", socksNoAuth),
            ("httpProxy", httpProxy), ("httpsProxy", httpsProxy),
            ("wireguard", wireguard),
        ]
    }

    /// Links that must be skipped, with a fragment of the expected reason.
    static var skipped: [(name: String, link: String, reason: String)] {
        [
            ("vlessH2", "vless://\(uuid)@srv.example.com:443?type=h2&security=tls#x", "removed from Xray"),
            ("vlessQuic", "vless://\(uuid)@srv.example.com:443?type=quic&security=tls#x", "removed from Xray"),
            ("vlessHTTP", "vless://\(uuid)@srv.example.com:443?type=http&security=tls#x", "removed from Xray"),
            ("vlessUnknownTransport", "vless://\(uuid)@srv.example.com:443?type=foo&security=tls#x", "unsupported transport"),
            ("vlessRealityNoKey", "vless://\(uuid)@srv.example.com:443?security=reality&sni=a.com#x", "public key"),
            ("vlessNoUUID", "vless://srv.example.com:443?security=tls#x", "UUID"),
            ("vlessBadPort", "vless://\(uuid)@srv.example.com:99999?security=tls#x", "port"),
            ("vlessNoPort", "vless://\(uuid)@srv.example.com?security=tls#x", "port"),
            ("vmessH2", vmessJSON(#"{"add":"a.com","port":"443","id":"\#(uuid)","net":"h2","tls":"tls"}"#), "removed from Xray"),
            ("vmessGarbage", "vmess://!!!notbase64!!!", "invalid vmess"),
            ("ssPlugin", "ss://\(b64url("aes-256-gcm:pw"))@1.2.3.4:8388/?plugin=v2ray-plugin%3Btls#x", "plugin"),
            ("hy2Pin", "hysteria2://pw@srv.example.com:443/?pinSHA256=AA:BB#x", "pinSHA256"),
            ("hy2OtherObfs", "hysteria2://pw@srv.example.com:443/?obfs=foo#x", "obfs"),
            ("wgNoPublicKey", "wireguard://\(wgPrivate)@1.2.3.4:51820?address=10.0.0.2#x", "public key"),
            ("trojanNoPassword", "trojan://srv.example.com:443#x", "password"),
            ("unknownScheme", "tuic://a@b.com:443#x", "unsupported scheme"),
        ]
    }
}
