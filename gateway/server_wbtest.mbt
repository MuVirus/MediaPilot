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

///|
test "is_absolute_path accepts drive, UNC, and POSIX paths" {
  assert_true(is_absolute_path("C:/work"))
  assert_true(is_absolute_path("C:\\work"))
  assert_true(is_absolute_path("/home/user"))
  assert_true(is_absolute_path("\\\\server\\share"))
  assert_false(is_absolute_path("work"))
  assert_false(is_absolute_path("./work"))
  assert_false(is_absolute_path("../work"))
  assert_false(is_absolute_path("C:"))
}

///|
test "percent_decode handles encoded paths and leaves plus alone" {
  assert_eq(percent_decode("D%3A%5Cwork"), "D:\\work")
  assert_eq(percent_decode("%2Fhome%2Fuser"), "/home/user")
  assert_eq(percent_decode("a+b"), "a+b")
  assert_eq(percent_decode("100%25"), "100%")
  assert_eq(percent_decode("%zz"), "%zz")
  assert_eq(percent_decode("plain"), "plain")
}

///|
test "parent_of stops at drive and POSIX roots" {
  assert_eq(parent_of("C:\\work\\alpha"), Some("C:\\work"))
  assert_eq(parent_of("C:\\work"), Some("C:\\"))
  assert_eq(parent_of("C:\\"), None)
  assert_eq(parent_of("/home/user"), Some("/home"))
  assert_eq(parent_of("/"), None)
}

///|
async test "Workspaces accepts any existing directory" {
  let base = @fs.tmpdir(prefix="mediapilot-workspace-")
  let child = @fs.realpath(base + "/child") catch { _ => base + "/child" }
  @fs.mkdir(child, recursive=true, allow_exist=true)
  let workspaces = Workspaces::new(@fs.realpath("."), true)
  match workspaces.resolve("") {
    Ok(path) => assert_true(path.length() > 0)
    Err(_) => fail("the default should resolve")
  }
  match workspaces.resolve(child) {
    Ok(path) =>
      assert_eq(
        path.replace_all(old="\\", new="/"),
        child.replace_all(old="\\", new="/"),
      )
    Err(message) => fail("an existing directory should resolve: " + message)
  }
  match workspaces.resolve(base + "/missing") {
    Ok(_) => fail("a missing directory must be rejected")
    Err(_) => ()
  }
  match workspaces.resolve("relative/path") {
    Ok(_) => fail("a relative path must be rejected")
    Err(_) => ()
  }
  @fs.rmdir(base, recursive=true, allow_missing=true)
}

///|
async test "Workspaces disabled rejects an explicit directory" {
  let workspaces = Workspaces::disabled()
  assert_false(workspaces.is_enabled())
  match workspaces.resolve("") {
    Ok(path) => assert_eq(path, "")
    Err(_) => fail("the empty request should resolve to an empty default")
  }
  match workspaces.resolve("/work/a") {
    Ok(_) => fail("a disabled deployment must reject explicit workspaces")
    Err(_) => ()
  }
}

///|
async test "list_directory returns only sorted subdirectories" {
  let base = @fs.tmpdir(prefix="mediapilot-listing-")
  @fs.mkdir(base + "/beta", recursive=true, allow_exist=true)
  @fs.mkdir(base + "/alpha", recursive=true, allow_exist=true)
  @fs.write_text(base + "/file.txt", "x")
  let listing = match list_directory(base) {
    Ok(listing) => listing
    Err(message) => fail("listing failed: " + message)
  }
  assert_eq(listing.path, @fs.realpath(base) catch { _ => base })
  assert_eq(listing.entries.length(), 2)
  assert_eq(listing.entries[0].name, "alpha")
  assert_eq(listing.entries[1].name, "beta")
  assert_false(listing.truncated)
  @fs.rmdir(base, recursive=true, allow_missing=true)
}

///|
async test "list_directory rejects relative and missing paths" {
  match list_directory("relative/path") {
    Ok(_) => fail("a relative path must be rejected")
    Err(_) => ()
  }
  match list_directory("/definitely/not/here-12345") {
    Ok(_) => fail("a missing path must be rejected")
    Err(_) => ()
  }
}
