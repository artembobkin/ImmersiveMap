// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

public struct ImmersiveMapTileSource: Equatable {
    public typealias AuthorizationMode = ImmersiveMapSettings.TileSettings.NetworkSettings.AuthorizationMode

    public var tileBaseURL: URL
    public var accessToken: String?
    public var authorization: AuthorizationMode

    public init(tileBaseURL: URL,
                accessToken: String? = nil,
                authorization: AuthorizationMode = .bearerHeader) {
        self.tileBaseURL = tileBaseURL
        self.accessToken = accessToken
        self.authorization = authorization
    }

    public static func url(_ tileBaseURL: URL) -> ImmersiveMapTileSource {
        ImmersiveMapTileSource(tileBaseURL: tileBaseURL)
    }

    public func token(_ accessToken: String?) -> ImmersiveMapTileSource {
        var source = self
        source.accessToken = accessToken
        source.authorization = .bearerHeader
        return source
    }

    public func accessToken(_ accessToken: String?,
                            parameterName: String = "access_token") -> ImmersiveMapTileSource {
        var source = self
        source.accessToken = accessToken
        source.authorization = .accessTokenQuery(parameterName: parameterName)
        return source
    }
}
