///|
test "query_token reads only the token parameter" {
  assert_eq(query_token("/api/realtime?token=abc"), Some("abc"))
  assert_eq(query_token("/api/realtime?x=1&token=abc"), Some("abc"))
  assert_eq(query_token("/api/realtime?x=1"), None)
  assert_eq(query_token("/api/realtime"), None)
}

///|
test "route_path strips the query string" {
  assert_eq(route_path("/api/realtime?token=abc"), "/api/realtime")
  assert_eq(route_path("/api/realtime"), "/api/realtime")
  assert_eq(route_path("/?x=1"), "/")
}

///|
test "request_authorized enforces the configured token" {
  let request : @http.RequestHeader = {
    meth: @http.Get,
    path: "/api/realtime?token=secret",
    headers: Map([]),
  }
  assert_true(request_authorized(request, "secret"))
  assert_false(request_authorized(request, "other"))
  assert_true(request_authorized(request, ""))
}

///|
test "SessionLimiter caps concurrent sessions and releases slots" {
  let limiter = SessionLimiter::new(2)
  assert_true(limiter.try_acquire())
  assert_true(limiter.try_acquire())
  assert_false(limiter.try_acquire())
  assert_eq(limiter.active(), 2)
  limiter.release()
  assert_eq(limiter.active(), 1)
  assert_true(limiter.try_acquire())
}
