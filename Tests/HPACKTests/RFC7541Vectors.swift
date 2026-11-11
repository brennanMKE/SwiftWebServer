/// RFC 7541 Appendix C examples: each step's encoded block, the header list it carries, and the
/// dynamic table (newest first) and its size afterwards.
struct RFC7541Step {
    var name: String
    var encoded: [UInt8]
    var fields: [Field]
    var table: [Field]
    var tableSize: Int
}

struct RFC7541Sequence {
    var name: String
    var tableSize: Int
    var huffman: Bool
    var steps: [RFC7541Step]
}

enum RFC7541Vectors {
    // MARK: C.2 Header field representations (each on a fresh 4096-byte table)

    static let c21 = RFC7541Step(
        name: "C.2.1",
        encoded: hex("400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572"),
        fields: [Field("custom-key", "custom-header")],
        table: [Field("custom-key", "custom-header")], tableSize: 55)

    static let c22 = RFC7541Step(
        name: "C.2.2",
        encoded: hex("040c 2f73 616d 706c 652f 7061 7468"),
        fields: [Field(":path", "/sample/path")], table: [], tableSize: 0)

    static let c23 = RFC7541Step(
        name: "C.2.3",
        encoded: hex("1008 7061 7373 776f 7264 0673 6563 7265 74"),
        fields: [Field("password", "secret")], table: [], tableSize: 0)

    static let c24 = RFC7541Step(
        name: "C.2.4", encoded: hex("82"), fields: [Field(":method", "GET")], table: [], tableSize: 0)

    static let representations = [c21, c22, c23, c24]

    // MARK: C.3 / C.4 Requests

    static let request1 = [
        Field(":method", "GET"), Field(":scheme", "http"), Field(":path", "/"),
        Field(":authority", "www.example.com"),
    ]
    static let request2 = [
        Field(":method", "GET"), Field(":scheme", "http"), Field(":path", "/"),
        Field(":authority", "www.example.com"), Field("cache-control", "no-cache"),
    ]
    static let request3 = [
        Field(":method", "GET"), Field(":scheme", "https"), Field(":path", "/index.html"),
        Field(":authority", "www.example.com"), Field("custom-key", "custom-value"),
    ]
    static let requestTable1 = [Field(":authority", "www.example.com")]
    static let requestTable2 = [Field("cache-control", "no-cache"), Field(":authority", "www.example.com")]
    static let requestTable3 = [
        Field("custom-key", "custom-value"), Field("cache-control", "no-cache"),
        Field(":authority", "www.example.com"),
    ]

    static let c3 = RFC7541Sequence(name: "C.3", tableSize: 4096, huffman: false, steps: [
        RFC7541Step(name: "C.3.1", encoded: hex("8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d"),
                    fields: request1, table: requestTable1, tableSize: 57),
        RFC7541Step(name: "C.3.2", encoded: hex("8286 84be 5808 6e6f 2d63 6163 6865"),
                    fields: request2, table: requestTable2, tableSize: 110),
        RFC7541Step(name: "C.3.3",
                    encoded: hex("8287 85bf 400a 6375 7374 6f6d 2d6b 6579 0c63 7573 746f 6d2d 7661 6c75 65"),
                    fields: request3, table: requestTable3, tableSize: 164),
    ])

    static let c4 = RFC7541Sequence(name: "C.4", tableSize: 4096, huffman: true, steps: [
        RFC7541Step(name: "C.4.1", encoded: hex("8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff"),
                    fields: request1, table: requestTable1, tableSize: 57),
        RFC7541Step(name: "C.4.2", encoded: hex("8286 84be 5886 a8eb 1064 9cbf"),
                    fields: request2, table: requestTable2, tableSize: 110),
        RFC7541Step(name: "C.4.3",
                    encoded: hex("8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf"),
                    fields: request3, table: requestTable3, tableSize: 164),
    ])

    // MARK: C.5 / C.6 Responses (256-byte table, so entries are evicted)

    static let date1 = "Mon, 21 Oct 2013 20:13:21 GMT"
    static let date2 = "Mon, 21 Oct 2013 20:13:22 GMT"
    static let location = "https://www.example.com"
    static let cookie = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"

    static let response1 = [
        Field(":status", "302"), Field("cache-control", "private"), Field("date", date1),
        Field("location", location),
    ]
    static let response2 = [
        Field(":status", "307"), Field("cache-control", "private"), Field("date", date1),
        Field("location", location),
    ]
    static let response3 = [
        Field(":status", "200"), Field("cache-control", "private"), Field("date", date2),
        Field("location", location), Field("content-encoding", "gzip"), Field("set-cookie", cookie),
    ]
    static let responseTable1 = [
        Field("location", location), Field("date", date1), Field("cache-control", "private"),
        Field(":status", "302"),
    ]
    static let responseTable2 = [
        Field(":status", "307"), Field("location", location), Field("date", date1),
        Field("cache-control", "private"),
    ]
    static let responseTable3 = [
        Field("set-cookie", cookie), Field("content-encoding", "gzip"), Field("date", date2),
    ]

    static let c5 = RFC7541Sequence(name: "C.5", tableSize: 256, huffman: false, steps: [
        RFC7541Step(
            name: "C.5.1",
            encoded: hex("""
                4803 3330 3258 0770 7269 7661 7465 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133
                2032 303a 3133 3a32 3120 474d 546e 1768 7474 7073 3a2f 2f77 7777 2e65 7861 6d70
                6c65 2e63 6f6d
                """),
            fields: response1, table: responseTable1, tableSize: 222),
        RFC7541Step(name: "C.5.2", encoded: hex("4803 3330 37c1 c0bf"),
                    fields: response2, table: responseTable2, tableSize: 222),
        RFC7541Step(
            name: "C.5.3",
            encoded: hex("""
                88c1 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133 2032 303a 3133 3a32 3220 474d
                54c0 5a04 677a 6970 7738 666f 6f3d 4153 444a 4b48 514b 425a 584f 5157 454f 5049
                5541 5851 5745 4f49 553b 206d 6178 2d61 6765 3d33 3630 303b 2076 6572 7369 6f6e
                3d31
                """),
            fields: response3, table: responseTable3, tableSize: 215),
    ])

    static let c6 = RFC7541Sequence(name: "C.6", tableSize: 256, huffman: true, steps: [
        RFC7541Step(
            name: "C.6.1",
            encoded: hex("""
                4882 6402 5885 aec3 771a 4b61 96d0 7abe 9410 54d4 44a8 2005 9504 0b81 66e0 82a6
                2d1b ff6e 919d 29ad 1718 63c7 8f0b 97c8 e9ae 82ae 43d3
                """),
            fields: response1, table: responseTable1, tableSize: 222),
        RFC7541Step(name: "C.6.2", encoded: hex("4883 640e ffc1 c0bf"),
                    fields: response2, table: responseTable2, tableSize: 222),
        RFC7541Step(
            name: "C.6.3",
            encoded: hex("""
                88c1 6196 d07a be94 1054 d444 a820 0595 040b 8166 e084 a62d 1bff c05a 839b d9ab
                77ad 94e7 821d d7f2 e6c7 b335 dfdf cd5b 3960 d5af 2708 7f36 72c1 ab27 0fb5 291f
                9587 3160 65c0 03ed 4ee5 b106 3d50 07
                """),
            fields: response3, table: responseTable3, tableSize: 215),
    ])

    static let sequences = [c3, c4, c5, c6]
}
