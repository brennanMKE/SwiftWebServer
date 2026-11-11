import Testing
import HTTPCore

@Suite struct HTTPFieldsViewTests {
    @Test func duplicatesArePreservedInOrder() {
        let (_, view) = FieldScanner.view(
            "Host: a\r\nAccept: text/html\r\nSet-Cookie: one\r\nX-Thing: 1\r\nSet-Cookie: two\r\nset-cookie: three")
        #expect(view.count == 6)
        #expect(view.valueStrings(for: .setCookie) == ["one", "two", "three"])
        #expect(view.count(of: .setCookie) == 3)
        #expect(view.pairs.map(\.1) == ["a", "text/html", "one", "1", "two", "three"])
        #expect(view[2].name == .setCookie)
        #expect(view[3].name == .unknown)
    }

    @Test func everyWellKnownNameIsFoundCaseInsensitively() {
        let names = HTTPFieldName.allCases.filter { $0.isWellKnown && !$0.isPseudoHeader }
        let lines = names.enumerated().map { i, name in
            "\(HTTPFieldNameTests.alternatingCase(name.canonicalName.description)): v\(i)"
        }.joined(separator: "\r\n")
        let (_, view) = FieldScanner.view(lines)
        #expect(view.count == names.count)
        for (i, name) in names.enumerated() {
            #expect(view.contains(name), "\(name)")
            #expect(view[i].name == name)
            #expect(view.firstValueString(for: name) == "v\(i)", "\(name)")
            // Lookup by name bytes in another case also resolves through the ID.
            var upper = Array(name.canonicalName.description.uppercased().utf8)
            let index = upper.withUnsafeMutableBufferPointer { view.firstIndex(named: $0.span) }
            #expect(index == i)
            // Names read back as the canonical lowercase bytes.
            #expect(view.nameString(at: i) == name.canonicalName.description)
        }
    }

    @Test func absentNamesAreNotFound() {
        let (_, view) = FieldScanner.view("Host: a\r\nX-Other: b")
        #expect(!view.contains(.contentLength))
        #expect(view.firstValue(for: .contentLength) == nil)
        #expect(Array(view.values(for: .contentLength)).isEmpty)
        #expect(!view.contains(.unknown))
        #expect(view.firstIndex(named: "x-missing") == nil)
    }

    @Test func unknownNamesRoundTrip() {
        let (_, view) = FieldScanner.view("X-Custom-Thing: hello world\r\nX-custom-thing: again\r\nWeird!#$Name: x")
        #expect(view.nameString(at: 0) == "X-Custom-Thing")
        #expect(view.valueString(at: 0) == "hello world")
        #expect(view.nameString(at: 2) == "Weird!#$Name")
        #expect(view.firstIndex(named: "x-custom-thing") == 0)
        #expect(view.firstIndex(named: "X-CUSTOM-THING") == 0)
        #expect(view.firstValue(named: "weird!#$name").map { view.string(of: $0) } == "x")
        // Unknown names survive a snapshot with their original bytes.
        let owned = view.snapshot()
        #expect(owned.pairs.map(\.0) == ["X-Custom-Thing", "X-custom-thing", "Weird!#$Name"])
        #expect(owned.pairs.map(\.1) == ["hello world", "again", "x"])
    }

    @Test func contentLengthRules() {
        #expect(FieldScanner.view("Host: a").1.contentLength() == .absent)
        #expect(FieldScanner.view("Content-Length: 42").1.contentLength() == .value(42))
        #expect(FieldScanner.view("Content-Length: 42\r\ncontent-length: 42").1.contentLength() == .value(42))
        #expect(FieldScanner.view("Content-Length: 42, 42").1.contentLength() == .value(42))
        // #0021: two different values are flagged.
        #expect(FieldScanner.view("Content-Length: 42\r\nContent-Length: 43").1.contentLength() == .conflicting)
        #expect(FieldScanner.view("Content-Length: 1, 2").1.contentLength() == .conflicting)
        #expect(FieldScanner.view("Content-Length: -1").1.contentLength() == .invalid)
        #expect(FieldScanner.view("Content-Length: 4x").1.contentLength() == .invalid)
        #expect(FieldScanner.view("Content-Length: ").1.contentLength() == .invalid)
        #expect(FieldScanner.view("Content-Length: 99999999999999999999999").1.contentLength() == .invalid)
        #expect(FieldScanner.view("Content-Length: 5\r\nContent-Length: x").1.contentLength() == .invalid)
    }

    @Test func listElements() {
        let (_, view) = FieldScanner.view(
            "Connection: keep-alive, Upgrade\r\nAccept: a/b;q=\"x,y\", , c/d\t\r\nConnection: close")
        var elements: [String] = []
        view.forEachListElement(of: .accept) { elements.append(view.string(of: $0)) }
        #expect(elements == ["a/b;q=\"x,y\"", "c/d"])
        #expect(view.containsListElement("upgrade", in: .connection))
        #expect(view.containsListElement("CLOSE", in: .connection))
        #expect(!view.containsListElement("keep", in: .connection))
        #expect(!view.containsListElement("close", in: .upgrade))
        #expect(view.lastListElement(of: .connection).map { view.string(of: $0) } == "close")
        #expect(view.firstValue(for: .connection, equalsCaseInsensitive: "KEEP-ALIVE, upgrade"))
    }

    @Test func quotedStringEscapesDoNotSplit() {
        let (_, view) = FieldScanner.view(#"Accept: "a\",b", c"#)
        var elements: [String] = []
        view.forEachListElement(of: .accept) { elements.append(view.string(of: $0)) }
        #expect(elements == [#""a\",b""#, "c"])
    }

    @Test func combinedValueJoinsDuplicates() {
        let (_, view) = FieldScanner.view("Cookie: a=1\r\nHost: h\r\nCookie: b=2\r\nCookie: c=3")
        var out = ByteBuffer()
        #expect(view.combinedValue(for: .cookie, separator: "; ", into: &out) == 3)
        #expect(out.withReadableSpan { ASCII.string(from: $0) } == "a=1; b=2; c=3")
        var accept = ByteBuffer()
        #expect(view.combinedValue(for: .accept, into: &accept) == 0)
        #expect(accept.isEmpty)
    }

    @Test func storageIsReusedWithoutGrowing() {
        let storage = HTTPRequestStorage(bufferCapacity: 4096, fieldCapacity: 16)
        let head = (0..<10).map { "X-Header-\($0): value \($0)" }.joined(separator: "\r\n")
        FieldScanner.fill(storage, with: head)
        let fieldCapacity = storage.fields.capacity
        let bufferCapacity = storage.buffer.capacity
        for _ in 0..<100 {
            storage.endRequest()
            storage.buffer.clear()
            #expect(storage.fields.isEmpty)
            FieldScanner.fill(storage, with: head)
            #expect(storage.fieldsView.count == 10)
        }
        #expect(storage.fields.capacity == fieldCapacity)
        #expect(storage.buffer.capacity == bufferCapacity)
    }

    @Test func viewValidityFollowsGeneration() {
        let (storage, view) = FieldScanner.view("Host: a")
        #expect(view.isValid)
        storage.endRequest()
        #expect(!view.isValid)
        #expect(storage.fieldsView.isValid)
    }
}

@Suite struct HTTPFieldsTests {
    @Test func emptyFieldsDoNotAllocate() {
        let fields = HTTPFields()
        #expect(fields.isEmpty)
        #expect(fields.capacity.bytes == 0)
    }

    @Test func appendStaticAndDecimalAndCustom() {
        var fields = HTTPFields()
        fields.append(.contentType, "text/html; charset=utf-8")
        fields.append(.contentLength, decimal: 1234)
        fields.append(name: "X-Powered-By", value: "sws")
        fields.append(name: "CACHE-CONTROL", value: "no-store")   // resolves to the well-known ID
        fields.append(.setCookie, string: "a=1")
        fields.append(.setCookie, "b=2")
        #expect(fields.pairs.map(\.0) == ["content-type", "content-length", "X-Powered-By", "cache-control", "set-cookie", "set-cookie"])
        #expect(fields.pairs.map(\.1) == ["text/html; charset=utf-8", "1234", "sws", "no-store", "a=1", "b=2"])
        #expect(fields[3].name == .cacheControl)
        #expect(fields[3].nameView.isEmpty)
        #expect(fields[2].name == .unknown)
        #expect(fields.contentLength() == .value(1234))
        #expect(fields.valueStrings(for: .setCookie) == ["a=1", "b=2"])
    }

    @Test func setReplacesAndRemoveKeepsOrder() {
        var fields = HTTPFields()
        fields.append(.contentLength, decimal: 1)
        fields.append(.server, "a")
        fields.append(.contentLength, decimal: 2)
        fields.append(.date, "d")
        fields.set(.contentLength, decimal: 3)
        #expect(fields.pairs.map(\.0) == ["server", "date", "content-length"])
        #expect(fields.contentLength() == .value(3))
        fields.removeAll(.server)
        #expect(!fields.contains(.server))
        #expect(fields.pairs.map(\.0) == ["date", "content-length"])
        fields.remove(at: 0)
        #expect(!fields.contains(.date))
        #expect(fields.contains(.contentLength))
        fields.set(.vary, "accept-encoding")
        #expect(fields.pairs.map(\.1) == ["3", "accept-encoding"])
    }

    @Test func removeAllKeepsCapacity() {
        var fields = HTTPFields(minimumCapacity: 8, arenaCapacity: 256)
        let before = fields.capacity
        for _ in 0..<50 {
            fields.removeAll()
            for i in 0..<8 { fields.append(.xRequestID, decimal: i) }
            #expect(fields.count == 8)
        }
        #expect(fields.capacity == before)
        fields.removeAll(keepingCapacity: false)
        #expect(fields.capacity.bytes == 0)
        #expect(fields.isEmpty)
    }

    @Test func snapshotOfViewIsIndependent() {
        let (storage, view) = FieldScanner.view("Host: example.com\r\nX-A: 1\r\nhost: dup")
        let owned = view.snapshot()
        storage.endRequest()
        storage.buffer.clear()
        FieldScanner.fill(storage, with: "Other: z")
        #expect(owned.pairs.map(\.0) == ["host", "X-A", "host"])
        #expect(owned.valueStrings(for: .host) == ["example.com", "dup"])
    }
}
