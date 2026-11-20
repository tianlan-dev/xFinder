import XCTest
@testable import xFinderKit

final class S3SignerTests: XCTestCase {
    let signer = S3Signer(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
    let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z
    let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// AWS documentation example "GET Object".
    func testGetObjectExample() {
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
        let s = signer.sign(method: "GET", url: url, query: [], headers: ["Range": "bytes=0-9"], payloadHash: emptyHash, date: date)
        XCTAssertEqual(s.canonicalRequest, """
        GET
        /test.txt

        host:examplebucket.s3.amazonaws.com
        range:bytes=0-9
        x-amz-content-sha256:\(emptyHash)
        x-amz-date:20130524T000000Z

        host;range;x-amz-content-sha256;x-amz-date
        \(emptyHash)
        """)
        XCTAssertEqual(s.signature, "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        XCTAssertEqual((s.headers["Authorization"] ?? s.headers["authorization"])?.replacingOccurrences(of: ", ", with: ","),
                       "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    /// AWS documentation example "GET Bucket (List Objects)".
    func testListObjectsExample() {
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/")!
        let q = [URLQueryItem(name: "prefix", value: "J"), URLQueryItem(name: "max-keys", value: "2")]
        let s = signer.sign(method: "GET", url: url, query: q, payloadHash: emptyHash, date: date)
        XCTAssertTrue(s.canonicalRequest.hasPrefix("GET\n/\nmax-keys=2&prefix=J\n"))
        XCTAssertEqual(s.signature, "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    func testCanonicalQueryAndHost() {
        let q = [URLQueryItem(name: "b", value: "a b/c"), URLQueryItem(name: "a", value: nil), URLQueryItem(name: "list-type", value: "2")]
        XCTAssertEqual(S3Signer.canonicalQuery(q), "a=&b=a%20b%2Fc&list-type=2")
        XCTAssertEqual(S3Signer.hostHeader(URL(string: "http://127.0.0.1:9099/x")!), "127.0.0.1:9099")
        XCTAssertEqual(S3Signer.hostHeader(URL(string: "https://s3.amazonaws.com/x")!), "s3.amazonaws.com")
    }

    func testAddressing() {
        XCTAssertTrue(S3FileSystem.isAWS(host: ""))
        XCTAssertTrue(S3FileSystem.isAWS(host: "s3.eu-west-1.amazonaws.com"))
        XCTAssertFalse(S3FileSystem.isAWS(host: "minio.local"))
        XCTAssertEqual(S3FileSystem.key("/a/b c.txt"), "a/b c.txt")
    }
}

final class S3ParsingTests: XCTestCase {
    func testList() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>b</Name><Prefix>dir/</Prefix><IsTruncated>true</IsTruncated>
          <NextContinuationToken>tok==</NextContinuationToken>
          <Contents><Key>dir/a &amp; b.txt</Key><LastModified>2024-01-02T03:04:05.000Z</LastModified><Size>12</Size></Contents>
          <Contents><Key>dir/c</Key><Size>0</Size></Contents>
          <CommonPrefixes><Prefix>dir/sub/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let r = try S3Parsing.parseList(Data(xml.utf8))
        XCTAssertEqual(r.objects.map(\.key), ["dir/a & b.txt", "dir/c"])
        XCTAssertEqual(r.objects[0].size, 12)
        XCTAssertEqual(r.objects[0].lastModified, Date(timeIntervalSince1970: 1_704_164_645))
        XCTAssertEqual(r.prefixes, ["dir/sub/"])
        XCTAssertTrue(r.isTruncated)
        XCTAssertEqual(r.continuationToken, "tok==")
    }

    func testErrors() {
        let xml = "<Error><Code>PermanentRedirect</Code><Message>Use the right endpoint.</Message><Region>eu-west-1</Region></Error>"
        let info = S3Parsing.parseError(Data(xml.utf8))
        XCTAssertEqual(info?.code, "PermanentRedirect")
        XCTAssertEqual(info?.region, "eu-west-1")
        XCTAssertNil(S3Parsing.parseError(Data("garbage".utf8)))
        XCTAssertNil(S3Parsing.error(status: 200, info: nil, path: "/a"))
        let skew = S3ErrorInfo(code: "RequestTimeTooSkewed", message: "", region: nil)
        if case .clockSkew? = S3Parsing.error(status: 403, info: skew, path: "/a") {} else { XCTFail() }
        if case .notFound? = S3Parsing.error(status: 404, info: nil, path: "/a") {} else { XCTFail() }
        if case .permissionDenied? = S3Parsing.error(status: 403, info: nil, path: "/a") {} else { XCTFail() }
    }
}

final class WebDAVParsingTests: XCTestCase {
    func testMultistatus() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/dav/docs/</D:href><D:propstat><D:prop>
            <D:resourcetype><D:collection/></D:resourcetype>
            <D:getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</D:getlastmodified>
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href>https://h.example/dav/docs/a%20b.txt</D:href><D:propstat><D:prop>
            <D:resourcetype/><D:getcontentlength>42</D:getcontentlength>
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
        """
        let entries = try WebDAVParsing.parseMultistatus(Data(xml.utf8))
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isCollection)
        XCTAssertEqual(entries[0].modificationDate, Date(timeIntervalSince1970: 1_704_164_645))
        XCTAssertFalse(entries[1].isCollection)
        XCTAssertEqual(entries[1].size, 42)
        XCTAssertEqual(WebDAVParsing.hrefPath(entries[1].href), "/dav/docs/a b.txt")
        XCTAssertThrowsError(try WebDAVParsing.parseMultistatus(Data("<a><b></a>".utf8)))
    }

    func testPaths() {
        XCTAssertEqual(WebDAVParsing.relativePath("/dav/docs/a", basePath: "/dav"), "/docs/a")
        XCTAssertEqual(WebDAVParsing.relativePath("/dav/", basePath: "dav"), "/")
        XCTAssertNil(WebDAVParsing.relativePath("/other/a", basePath: "/dav"))
        XCTAssertNil(WebDAVParsing.relativePath("/davx/a", basePath: "/dav"))
        XCTAssertEqual(WebDAVParsing.relativePath("/a/b", basePath: ""), "/a/b")
        if case .parentMissing? = WebDAVParsing.error(status: 409, path: "/x") {} else { XCTFail() }
        if case .locked? = WebDAVParsing.error(status: 423, path: "/x") {} else { XCTFail() }
        XCTAssertNil(WebDAVParsing.error(status: 207, path: "/x"))
    }
}

final class FTPParsingTests: XCTestCase {
    func testReplies() {
        let (r, n) = FTPParsing.reply(from: ["230-Welcome", "  more text", "230 Logged in"])!
        XCTAssertEqual(r.code, 230)
        XCTAssertEqual(n, 3)
        XCTAssertTrue(r.isSuccess)
        XCTAssertNil(FTPParsing.reply(from: ["230-Welcome", "still going"]))
        XCTAssertEqual(FTPParsing.reply(from: ["331 Password required"])?.0.message, "Password required")
    }

    func testPassiveAndPWD() {
        XCTAssertEqual(FTPParsing.epsvPort("229 Entering Extended Passive Mode (|||6446|)"), 6446)
        XCTAssertEqual(FTPParsing.pasvPort("227 Entering Passive Mode (192,168,1,2,19,137)"), 19 * 256 + 137)
        XCTAssertNil(FTPParsing.pasvPort("227 nonsense"))
        XCTAssertEqual(FTPParsing.pwdPath("257 \"/home/a \"\"q\"\"\" is current directory"), "/home/a \"q\"")
        let feat = FTPReply(code: 211, lines: ["211-Features:", " MLST type*;size*;modify*;", " UTF8", " REST STREAM", "211 End"])
        XCTAssertTrue(FTPParsing.features(feat).isSuperset(of: ["MLST", "UTF8", "REST"]))
    }

    func testTimeval() {
        let d = FTPParsing.timeval("20240102030405")
        XCTAssertEqual(d, Date(timeIntervalSince1970: 1_704_164_645))
        XCTAssertEqual(FTPParsing.formatTimeval(d!), "20240102030405")
        XCTAssertNotNil(FTPParsing.timeval("20240102030405.123"))
    }

    func testMLSD() {
        let f = FTPParsing.mlsdEntry("type=file;size=1024;modify=20240102030405;UNIX.mode=0640; report.pdf", directory: "/docs")
        XCTAssertEqual(f?.name, "report.pdf")
        XCTAssertEqual(f?.path, "/docs/report.pdf")
        XCTAssertEqual(f?.size, 1024)
        XCTAssertEqual(f?.permissions, 0o640)
        let d = FTPParsing.mlsdEntry("type=dir;modify=20240102030405; sub dir", directory: "/")
        XCTAssertEqual(d?.isDirectory, true)
        XCTAssertEqual(d?.name, "sub dir")
        XCTAssertNil(FTPParsing.mlsdEntry("type=cdir; .", directory: "/"))
        XCTAssertNil(FTPParsing.mlsdEntry("type=pdir; ..", directory: "/"))
    }

    func testUnixList() {
        let now = Date(timeIntervalSince1970: 1_704_164_645) // 2024-01-02
        let f = FTPParsing.listEntry("-rw-r--r--   1 owner group     2048 Dec 25 10:30 notes file.txt", directory: "/", now: now)
        XCTAssertEqual(f?.name, "notes file.txt")
        XCTAssertEqual(f?.size, 2048)
        XCTAssertEqual(f?.permissions, 0o644)
        // A date in the "future" belongs to the previous year.
        XCTAssertEqual(Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: f!.modificationDate!).year, 2023)
        let d = FTPParsing.listEntry("drwxr-xr-x   2 o g 4096 Mar  1  2021 www", directory: "/srv", now: now)
        XCTAssertEqual(d?.isDirectory, true)
        XCTAssertEqual(d?.path, "/srv/www")
        let l = FTPParsing.listEntry("lrwxrwxrwx 1 o g 7 Jan  1 2020 current -> releases/1", directory: "/", now: now)
        XCTAssertEqual(l?.name, "current")
        XCTAssertEqual(l?.type, .symlink)
        XCTAssertNil(FTPParsing.listEntry("total 12", directory: "/", now: now))
    }

    func testWindowsList() {
        let f = FTPParsing.listEntry("01-02-24  03:04PM                 1234 file.txt", directory: "/", now: Date())
        XCTAssertEqual(f?.name, "file.txt")
        XCTAssertEqual(f?.size, 1234)
        let d = FTPParsing.listEntry("01-02-24  03:04AM       <DIR>          My Docs", directory: "/", now: Date())
        XCTAssertEqual(d?.isDirectory, true)
        XCTAssertEqual(d?.name, "My Docs")
    }

    func testModesAndErrors() {
        XCTAssertEqual(FTPParsing.parseSymbolicMode("-rwxr-x---"), 0o750)
        XCTAssertEqual(FTPParsing.parseSymbolicMode("drwsr-xr-t"), 0o4755 | 0o1000)
        XCTAssertNil(FTPParsing.parseSymbolicMode("bogus"))
        if case .authenticationFailed = FTPParsing.error(FTPReply(code: 530, lines: ["530 Login incorrect"]), path: "/") {} else { XCTFail() }
        if case .notFound = FTPParsing.error(FTPReply(code: 550, lines: ["550 No such file or directory"]), path: "/x") {} else { XCTFail() }
        if case .insufficientStorage = FTPParsing.error(FTPReply(code: 552, lines: ["552 Quota exceeded"]), path: "/x") {} else { XCTFail() }
    }
}
