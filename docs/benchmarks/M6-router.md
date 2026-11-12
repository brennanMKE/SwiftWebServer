# M6: Router (#0094)

What matching a request against a 50-route table costs, and whether it allocates.

- Date: 2026-11-11, 18:05 PST
- Branch: `m06-router` (from `main` `5f33eb4`)
- Load average (1, 5, 15 min): 8.17 13.92 27.52 before, 8.63 13.92 27.45 after (other agents
  building and testing). Not a gating record.

## Machine

| | |
|---|---|
| CPU | Apple M4 Pro (12 cores) |
| OS | macOS 27.0 |
| Swift | Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1) |
| Build | `swift build -c release -j 2 --product sws-bench` |
| Command | `sws-bench router` (same as `sws-bench micro --filter Router`), 3 runs |

## Table

Fifty routes: ten REST resources under `Group("/api/v1")`, each with `GET` and `POST` on
`/<resource>` and `GET`, `PUT` and `DELETE` on `/<resource>/:id`. One op is one
`Router.match(request)` on a prebuilt request (path bytes in an `HTTPRequestStorage`), which is
everything the router does before calling the handler or `next`.

## Results

Median ns per op over three runs (min of the three medians in brackets).

| Case | Request | ns/op | allocs/op |
|---|---|---|---|
| static hit | `GET /api/v1/sessions` | 36.8 (36.7) | 0.00 |
| param hit | `GET /api/v1/sessions/123456` | 45.8 (45.2) | 0.00 |
| param hit + `params.decimal("id")` | `DELETE /api/v1/sessions/123456` | 59.8 (58.9) | 0.00 |
| `HEAD` served by the `GET` route | `HEAD /api/v1/orders/42` | 49.6 (48.1) | 0.00 |
| miss, falls through to `next` | `GET /assets/app.js` | 17.3 (16.6) | 0.00 |
| miss under the prefix | `GET /api/v1/unknown/1` | 28.5 (28.5) | 0.00 |
| `405` with prebuilt `Allow` | `PATCH /api/v1/orders/42` | 81.3 (80.0) | 0.00 |

- Hits, misses and the single-pattern `405` allocate nothing. Captures are byte ranges held
  inline in `RouteParameters`; a `String` is made only when a handler reads `params["id"]`.
- A miss outside every prefix costs one segment scan and one binary search at the root.
- The `405` costs a second, allocation-free walk that counts the patterns matching the path; when
  more than one does, the combined `Allow` is built per request (allocates; not benchmarked).
- An earlier version collected the matching patterns into an array for the `405`: 110 ns and
  1 allocation per op.

## Unregistered

The Router is a middleware in its own target. A server that does not put it in its builder
chain does not compile it into the request path (docs/MIDDLEWARE.md), and #0094 changes no code
in `HTTPCore`, `HTTP1`, `HTTP2`, `HTTP3` or `HTTPServer`, so the unregistered cost is unchanged
by construction; `h1conn` was not rerun for this record (other agents were building).
