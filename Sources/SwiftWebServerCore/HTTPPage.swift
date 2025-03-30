import Foundation

public struct HTTPPage: Sendable {
    public static let `default` = HTTPPage()

    public init() {}

    private let page =
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <title>TITLE</title>
          <style>
            body {
              font-family: sans-serif;
              background-color: #f4f4f4;
              padding: 2em;
              color: #333;
            }
            h1 {
              color: #007aff;
            }
          </style>
        </head>
        <body>
          <h1>TITLE</h1>
          <p>MESSAGE</p>
        </body>
        </html>
        """

    public func page(for status: Status) -> String {
        switch status {
        case .ok:
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <title>200 OK</title>
            </head>
            <body>
                <h1>200 OK</h1>
                <p>The request has succeeded.</p>
            </body>
            </html>
            """
        case .notFound:
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <title>404 Not Found</title>
            </head>
            <body>
                <h1>404 Not Found</h1>
                <p>The requested resource could not be found.</p>
            </body>
            </html>
            """
        case .badRequest:
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <title>400 Bad Request</title>
            </head>
            <body>
                <h1>400 Bad Request</h1>
                <p>The request could not be understood by the server.</p>
            </body>
            </html>
            """
        case .internalServerError:
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <title>500 Internal Server Error</title>
            </head>
            <body>
                <h1>500 Internal Server Error</h1>
                <p>The server encountered an unexpected condition.</p>
            </body>
            </html>
            """
        case .switchingProtocols:
            return "" // No HTML needed for protocol switch
        case .notModified:
            return "" // No HTML needed for not modified
        case .forbidden:
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <title>403 Forbidden</title>
            </head>
            <body>
                <h1>403 Forbidden</h1>
                <p>You don't have permission to access this resource.</p>
            </body>
            </html>
            """
        case .methodNotAllowed:
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <title>405 Method Not Allowed</title>
            </head>
            <body>
                <h1>405 Method Not Allowed</h1>
                <p>The method specified in the request is not allowed.</p>
            </body>
            </html>
            """
        }
    }
}
