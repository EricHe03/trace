//
//  DNSRecordType.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// DNS Resource Record Types (RFC 1035 and extensions)
public enum DNSRecordType: UInt16, Codable, CaseIterable, Sendable {
    // Common types
    case a = 1 // Host address (IPv4)
    case ns = 2 // Authoritative name server
    case md = 3 // Mail destination (obsolete)
    case mf = 4 // Mail forwarder (obsolete)
    case cname = 5 // Canonical name for an alias
    case soa = 6 // Start of authority zone
    case mb = 7 // Mailbox domain name (experimental)
    case mg = 8 // Mail group member (experimental)
    case mr = 9 // Mail rename domain name (experimental)
    case null = 10 // Null RR (experimental)
    case wks = 11 // Well known service
    case ptr = 12 // Domain name pointer
    case hinfo = 13 // Host information
    case minfo = 14 // Mailbox or mail list information
    case mx = 15 // Mail exchange
    case txt = 16 // Text strings
    case rp = 17 // Responsible person
    case afsdb = 18 // AFS database location
    case x25 = 19 // X.25 address
    case isdn = 20 // ISDN address
    case rt = 21 // Route through
    case nsap = 22 // OSI NSAP
    case nsapPtr = 23 // PTR equivalent for OSI NSAP
    case sig = 24 // Digital signature
    case key = 25 // Public key
    case px = 26 // Pointer to X.400/RFC822 mapping info
    case gpos = 27 // Geographical position
    case aaaa = 28 // IPv6 address
    case loc = 29 // Geographical location
    case nxt = 30 // Next name
    case eid = 31 // Endpoint identifier
    case nimloc = 32 // Nimrod locator
    case srv = 33 // Service location
    case atma = 34 // ATM address
    case naptr = 35 // Naming authority pointer
    case kx = 36 // Key exchange
    case cert = 37 // Certificate
    case a6 = 38 // IPv6 address with indirection (obsolete)
    case dname = 39 // Non-terminal DNS name redirection
    case sink = 40 // Sink
    case opt = 41 // OPT pseudo-RR
    case apl = 42 // Lists of address prefixes
    case ds = 43 // Delegation signer
    case sshfp = 44 // SSH key fingerprint
    case ipseckey = 45 // IPsec key
    case rrsig = 46 // DNSSEC signature
    case nsec = 47 // Next secure
    case dnskey = 48 // DNS public key
    case dhcid = 49 // DHCP identifier
    case nsec3 = 50 // Next secure hash
    case nsec3param = 51 // NSEC3 parameters
    case tlsa = 52 // TLSA certificate association
    case smimea = 53 // S/MIME certificate association
    case hip = 55 // Host Identity Protocol
    case ninfo = 56 // NINFO
    case rkey = 57 // RKEY
    case talink = 58 // Trust anchor link
    case cds = 59 // Child DS
    case cdnskey = 60 // Child DNSKEY
    case openpgpkey = 61 // OpenPGP public key
    case csync = 62 // Child-to-parent synchronization
    case zonemd = 63 // Message digest for DNS zones
    case svcb = 64 // Service binding
    case https = 65 // HTTPS binding
    case spf = 99 // SPF (Sender Policy Framework)
    case uinfo = 100 // Reserved
    case uid = 101 // Reserved
    case gid = 102 // Reserved
    case unspec = 103 // Reserved
    case nid = 104 // Node identifier
    case l32 = 105 // 32-bit locator
    case l64 = 106 // 64-bit locator
    case lp = 107 // Locator pointer
    case eui48 = 108 // EUI-48 address
    case eui64 = 109 // EUI-64 address
    case tkey = 249 // Transaction key
    case tsig = 250 // Transaction signature
    case ixfr = 251 // Incremental zone transfer
    case axfr = 252 // Transfer of entire zone
    case mailb = 253 // Mailbox-related RRs
    case maila = 254 // Mail agent RRs (obsolete)
    case any = 255 // Request for all records
    case uri = 256 // Uniform Resource Identifier
    case caa = 257 // Certification Authority Authorization
    case avc = 258 // Application Visibility and Control
    case doa = 259 // Digital Object Architecture
    case amtrelay = 260 // Automatic Multicast Tunneling Relay
    case ta = 32768 // DNSSEC trust authorities
    case dlv = 32769 // DNSSEC lookaside validation

    public var displayName: String {
        switch self {
        case .a: "A"
        case .ns: "NS"
        case .md: "MD"
        case .mf: "MF"
        case .cname: "CNAME"
        case .soa: "SOA"
        case .mb: "MB"
        case .mg: "MG"
        case .mr: "MR"
        case .null: "NULL"
        case .wks: "WKS"
        case .ptr: "PTR"
        case .hinfo: "HINFO"
        case .minfo: "MINFO"
        case .mx: "MX"
        case .txt: "TXT"
        case .rp: "RP"
        case .afsdb: "AFSDB"
        case .x25: "X25"
        case .isdn: "ISDN"
        case .rt: "RT"
        case .nsap: "NSAP"
        case .nsapPtr: "NSAP-PTR"
        case .sig: "SIG"
        case .key: "KEY"
        case .px: "PX"
        case .gpos: "GPOS"
        case .aaaa: "AAAA"
        case .loc: "LOC"
        case .nxt: "NXT"
        case .eid: "EID"
        case .nimloc: "NIMLOC"
        case .srv: "SRV"
        case .atma: "ATMA"
        case .naptr: "NAPTR"
        case .kx: "KX"
        case .cert: "CERT"
        case .a6: "A6"
        case .dname: "DNAME"
        case .sink: "SINK"
        case .opt: "OPT"
        case .apl: "APL"
        case .ds: "DS"
        case .sshfp: "SSHFP"
        case .ipseckey: "IPSECKEY"
        case .rrsig: "RRSIG"
        case .nsec: "NSEC"
        case .dnskey: "DNSKEY"
        case .dhcid: "DHCID"
        case .nsec3: "NSEC3"
        case .nsec3param: "NSEC3PARAM"
        case .tlsa: "TLSA"
        case .smimea: "SMIMEA"
        case .hip: "HIP"
        case .ninfo: "NINFO"
        case .rkey: "RKEY"
        case .talink: "TALINK"
        case .cds: "CDS"
        case .cdnskey: "CDNSKEY"
        case .openpgpkey: "OPENPGPKEY"
        case .csync: "CSYNC"
        case .zonemd: "ZONEMD"
        case .svcb: "SVCB"
        case .https: "HTTPS"
        case .spf: "SPF"
        case .uinfo: "UINFO"
        case .uid: "UID"
        case .gid: "GID"
        case .unspec: "UNSPEC"
        case .nid: "NID"
        case .l32: "L32"
        case .l64: "L64"
        case .lp: "LP"
        case .eui48: "EUI48"
        case .eui64: "EUI64"
        case .tkey: "TKEY"
        case .tsig: "TSIG"
        case .ixfr: "IXFR"
        case .axfr: "AXFR"
        case .mailb: "MAILB"
        case .maila: "MAILA"
        case .any: "ANY"
        case .uri: "URI"
        case .caa: "CAA"
        case .avc: "AVC"
        case .doa: "DOA"
        case .amtrelay: "AMTRELAY"
        case .ta: "TA"
        case .dlv: "DLV"
        }
    }

    public var description: String {
        switch self {
        case .a: "IPv4 host address"
        case .aaaa: "IPv6 host address"
        case .cname: "Canonical name for an alias"
        case .mx: "Mail exchange"
        case .ns: "Authoritative name server"
        case .ptr: "Domain name pointer"
        case .soa: "Start of authority"
        case .txt: "Text strings"
        case .srv: "Service locator"
        case .caa: "Certification Authority Authorization"
        case .any: "Request for all records"
        default: displayName
        }
    }

    /// Common DNS record types for filtering
    public static var common: [DNSRecordType] {
        [.a, .aaaa, .cname, .mx, .ns, .ptr, .soa, .txt, .srv]
    }
}

/// DNS Class values (RFC 1035)
public enum DNSClass: UInt16, Codable, Sendable {
    case `in` = 1 // Internet
    case cs = 2 // CSNET (obsolete)
    case ch = 3 // CHAOS
    case hs = 4 // Hesiod
    case none = 254 // None
    case any = 255 // Any class

    public var displayName: String {
        switch self {
        case .in: "IN"
        case .cs: "CS"
        case .ch: "CH"
        case .hs: "HS"
        case .none: "NONE"
        case .any: "ANY"
        }
    }

    public var description: String {
        switch self {
        case .in: "Internet"
        case .cs: "CSNET"
        case .ch: "CHAOS"
        case .hs: "Hesiod"
        case .none: "None"
        case .any: "Any class"
        }
    }
}

/// DNS Response Code (RCODE)
public enum DNSResponseCode: UInt8, Codable, Sendable {
    case noError = 0 // No error
    case formatError = 1 // Format error
    case serverFailure = 2 // Server failure
    case nameError = 3 // Name error (NXDOMAIN)
    case notImplemented = 4 // Not implemented
    case refused = 5 // Query refused
    case yxDomain = 6 // Name exists when it should not
    case yxRRSet = 7 // RR set exists when it should not
    case nxRRSet = 8 // RR set that should exist does not
    case notAuth = 9 // Server not authoritative for zone
    case notZone = 10 // Name not contained in zone

    public var displayName: String {
        switch self {
        case .noError: "NOERROR"
        case .formatError: "FORMERR"
        case .serverFailure: "SERVFAIL"
        case .nameError: "NXDOMAIN"
        case .notImplemented: "NOTIMP"
        case .refused: "REFUSED"
        case .yxDomain: "YXDOMAIN"
        case .yxRRSet: "YXRRSET"
        case .nxRRSet: "NXRRSET"
        case .notAuth: "NOTAUTH"
        case .notZone: "NOTZONE"
        }
    }

    public var description: String {
        switch self {
        case .noError: "No error"
        case .formatError: "Format error"
        case .serverFailure: "Server failure"
        case .nameError: "Name does not exist"
        case .notImplemented: "Not implemented"
        case .refused: "Query refused"
        case .yxDomain: "Name exists when it should not"
        case .yxRRSet: "RR set exists when it should not"
        case .nxRRSet: "RR set that should exist does not"
        case .notAuth: "Server not authoritative for zone"
        case .notZone: "Name not contained in zone"
        }
    }

    public var isSuccess: Bool {
        self == .noError
    }
}

/// DNS Opcode
public enum DNSOpcode: UInt8, Codable, Sendable {
    case query = 0 // Standard query
    case iquery = 1 // Inverse query (obsolete)
    case status = 2 // Server status request
    case notify = 4 // Notify
    case update = 5 // Dynamic update
    case dso = 6 // DNS Stateful Operations

    public var displayName: String {
        switch self {
        case .query: "QUERY"
        case .iquery: "IQUERY"
        case .status: "STATUS"
        case .notify: "NOTIFY"
        case .update: "UPDATE"
        case .dso: "DSO"
        }
    }
}
