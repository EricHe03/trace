//
//  RequestDetailViewModel.swift
//  Trace
//
//  Created by Justin on 2026/02/06.
//

import Combine
import Foundation
import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI

enum DetailTab: String, CaseIterable {
    case overview = "Overview"
    case requestHeaders = "Request"
    case responseHeaders = "Response"
    case body = "Body"
    case sse = "SSE Events"
}

@MainActor
final class RequestDetailViewModel: ObservableObject {
    @Published var selectedTab: DetailTab = .overview
    @Published var shareSheetItem: ShareSheetItem?
    @Published var toastMessage: String?
    @Published private(set) var requestBodyText: String?
    @Published private(set) var responseBodyText: String?
    @Published private(set) var requestBodyRawData: Data?
    @Published private(set) var responseBodyRawData: Data?
    @Published private(set) var isRequestBodyPreview = false
    @Published private(set) var isResponseBodyPreview = false
    @Published private(set) var isLoadingRequestBody = false
    @Published private(set) var isLoadingResponseBody = false

    func availableTabs(for request: NetworkRequest) -> [DetailTab] {
        var tabs: [DetailTab] = [.overview, .requestHeaders, .responseHeaders, .body]
        if request.isSSE {
            tabs.append(.sse)
        }
        return tabs
    }

    func loadInitialBodyPreview(for request: NetworkRequest) async {
        await loadRequestBody(for: request, full: false)
        await loadResponseBody(for: request, full: false)
    }

    func loadRequestBody(for request: NetworkRequest, full: Bool) async {
        guard !request.requestBody.isEmpty else { return }

        isLoadingRequestBody = true
        let limit = full ? nil : BodyStorage.previewSize
        let contentType = requestContentType(from: request)?.lowercased()
        let isBinary = RequestDetailBodyAnalyzer.isBinaryContentType(contentType)

        if isBinary {
            requestBodyRawData = await Task.detached(priority: .userInitiated) {
                if let limit {
                    return request.requestBody.getPreview(maxBytes: limit)
                }
                return request.requestBody.getData()
            }.value

            let kind = RequestDetailBodyAnalyzer.detectBinaryKind(
                data: requestBodyRawData,
                contentType: contentType,
                fileName: nil
            )
            requestBodyText = RequestDetailBodyAnalyzer.binarySummaryText(
                kind: kind,
                fileName: nil,
                totalSize: request.requestBody.totalSize,
                previewSize: requestBodyRawData?.count,
                isPreview: !full && request.requestBody.totalSize > BodyStorage.previewSize
            )
        } else {
            if contentType?.hasPrefix("image/") == true {
                requestBodyRawData = await Task.detached(priority: .userInitiated) {
                    if let limit {
                        return request.requestBody.getPreview(maxBytes: limit)
                    }
                    return request.requestBody.getData()
                }.value
            } else {
                requestBodyRawData = nil
            }

            requestBodyText = await Task.detached(priority: .userInitiated) {
                if let limit {
                    return request.requestBody.getString(maxBytes: limit)
                }
                return request.requestBody.getString()
            }.value
        }

        isRequestBodyPreview = !full && request.requestBody.totalSize > BodyStorage.previewSize
        isLoadingRequestBody = false
    }

    func loadResponseBody(for request: NetworkRequest, full: Bool) async {
        guard !request.responseBody.isEmpty else { return }

        isLoadingResponseBody = true
        let limit = full ? nil : BodyStorage.previewSize
        let contentType = responseContentType(from: request)?.lowercased()
        let contentDisposition = responseContentDisposition(from: request)
        let fileName = RequestDetailBodyAnalyzer.attachmentFileName(from: contentDisposition)
        let isAttachment = contentDisposition?.lowercased().contains("attachment") == true
        let isBinary = request.isBinary || RequestDetailBodyAnalyzer.isBinaryContentType(contentType) || isAttachment

        if isBinary {
            responseBodyRawData = await Task.detached(priority: .userInitiated) {
                if let limit {
                    return request.responseBody.getPreview(maxBytes: limit)
                }
                return request.responseBody.getData()
            }.value

            let kind = RequestDetailBodyAnalyzer.detectBinaryKind(
                data: responseBodyRawData,
                contentType: contentType,
                fileName: fileName
            )
            responseBodyText = RequestDetailBodyAnalyzer.binarySummaryText(
                kind: kind,
                fileName: fileName,
                totalSize: request.responseBody.totalSize,
                previewSize: responseBodyRawData?.count,
                isPreview: !full && request.responseBody.totalSize > BodyStorage.previewSize
            )
        } else {
            if contentType?.hasPrefix("image/") == true {
                responseBodyRawData = await Task.detached(priority: .userInitiated) {
                    if let limit {
                        return request.responseBody.getPreview(maxBytes: limit)
                    }
                    return request.responseBody.getData()
                }.value
            } else {
                responseBodyRawData = nil
            }

            responseBodyText = await Task.detached(priority: .userInitiated) {
                if let limit {
                    return request.responseBody.getString(maxBytes: limit)
                }
                return request.responseBody.getString()
            }.value
        }

        isResponseBodyPreview = !full && request.responseBody.totalSize > BodyStorage.previewSize
        isLoadingResponseBody = false
    }

    func requestContentType(from request: NetworkRequest) -> String? {
        request.requestHeaders.first { $0.key.lowercased() == "content-type" }?.value
    }

    func responseContentType(from request: NetworkRequest) -> String? {
        request.responseHeaders.first { $0.key.lowercased() == "content-type" }?.value
    }

    func responseContentDisposition(from request: NetworkRequest) -> String? {
        request.responseHeaders.first { $0.key.lowercased() == "content-disposition" }?.value
    }

    func responseAttachmentFilename(from request: NetworkRequest) -> String? {
        RequestDetailBodyAnalyzer.attachmentFileName(from: responseContentDisposition(from: request))
    }

    func copyToClipboard(_ text: String, toastMessage: String = "Copied to clipboard") {
        DesignSystem.Haptics.light()
        UIPasteboard.general.string = text
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            self.toastMessage = toastMessage
        }
    }

    func copyRequestAsCurl(for request: NetworkRequest) {
        let curl = CurlCommandGenerator.generate(from: request)
        copyToClipboard(curl, toastMessage: "cURL copied to clipboard")
    }

    func shareFullRequest(for request: NetworkRequest) {
        shareSheetItem = ShareSheetItem(
            [
                formatRequestForSharing(request),
                CurlCommandGenerator.generate(from: request)
            ],
            applicationActivities: ActivityHelper.customActivitiesForRequest()
        )
    }

    func shareRequestBody(for request: NetworkRequest) {
        shareSheetItem = ShareSheetItem(
            ShareHelper.shareItemsForRequestBody(
                from: request,
                bodyText: requestBodyText,
                bodyData: requestBodyRawData
            )
        )
    }

    func shareResponseBody(for request: NetworkRequest) {
        shareSheetItem = ShareSheetItem(
            ShareHelper.shareItemsForResponseBody(
                from: request,
                bodyText: responseBodyText,
                bodyData: responseBodyRawData
            )
        )
    }

    private func formatRequestForSharing(_ request: NetworkRequest) -> String {
        var text = "Network Request\n\n"
        text += "URL: \(request.url)\n"
        text += "Method: \(request.method.rawValue)\n"
        text += "Status: \(request.statusCodeText)\n"
        text += "Time: \(request.timestamp.formatted(date: .abbreviated, time: .standard))\n"
        text += "\nRequest Headers:\n"

        let requestBodyIsEmpty = request.requestBody.isEmpty
        for header in request.requestHeaders {
            if header.key.lowercased() == "content-length",
               requestBodyIsEmpty,
               header.value.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
                continue
            }
            text += "  \(header.key): \(header.value)\n"
        }

        if !request.requestBody.isEmpty {
            let contentType = requestContentType(from: request)
            let isRequestBinary = RequestDetailBodyAnalyzer.isBinaryContentType(contentType)

            if isRequestBinary {
                let size = request.requestBody.totalSize
                text += "\nRequest Body:\n<binary body omitted> (size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))\n"
            } else if let requestBodyText, !requestBodyText.isEmpty {
                text += "\nRequest Body:\n\(requestBodyText)\n"
                if isRequestBodyPreview {
                    text += "\n(Request body truncated to preview)\n"
                }
            } else {
                text += "\nRequest Body:\n<not loaded>\n"
            }
        }

        text += "\nResponse Headers:\n"
        for header in request.responseHeaders {
            if header.key.lowercased() == "content-type" {
                let lowerValue = header.value.lowercased()
                if lowerValue.contains("octet-stream"),
                   let inferred = RequestDetailBodyAnalyzer.inferredContentType(from: request.url),
                   inferred.lowercased() != lowerValue {
                    text += "  \(header.key): \(header.value) (inferred: \(inferred))\n"
                    continue
                }
            }
            text += "  \(header.key): \(header.value)\n"
        }

        if !request.responseBody.isEmpty {
            let contentType = responseContentType(from: request)
            let contentDisposition = responseContentDisposition(from: request)
            let fileName = RequestDetailBodyAnalyzer.attachmentFileName(from: contentDisposition)
            let isAttachment = contentDisposition?.lowercased().contains("attachment") == true
            let isResponseBinary = request.isBinary || RequestDetailBodyAnalyzer.isBinaryContentType(contentType) || isAttachment

            if isResponseBinary {
                let size = request.responseBody.totalSize
                text += "\nResponse Body:\n<binary body omitted> (size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))\n"
                if let fileName, !fileName.isEmpty {
                    text += "Filename: \(fileName)\n"
                }
            } else if let responseBodyText, !responseBodyText.isEmpty {
                text += "\nResponse Body:\n\(responseBodyText)\n"
                if isResponseBodyPreview {
                    text += "\n(Response body truncated to preview)\n"
                }
            } else {
                text += "\nResponse Body:\n<not loaded>\n"
            }
        }

        text += "\ncURL Command:\n"
        text += CurlCommandGenerator.generate(from: request)

        return text
    }
}
