import Foundation

struct HTTPPage {
    static let `default` = HTTPPage()

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

    func page(for status: HTTPStatus) -> String {
        page
            .replacingOccurrences(of: "TITLE", with: "HTTP Status: \(status.rawValue)")
            .replacingOccurrences(of: "MESSAGE", with: status.statusText)
    }
}
