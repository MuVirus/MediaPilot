///|
test "parse_env_text ignores comments and keeps the first equals" {
  let entries = @config.parse_env_text(
    "# comment\n\nA=1\nexport B = \"two=2\"\nC='three'\nINVALID\n",
  )
  assert_eq(entries.length(), 3)
  assert_eq(entries[0], ("A", "1"))
  assert_eq(entries[1], ("B", "two=2"))
  assert_eq(entries[2], ("C", "three"))
}

///|
test "strip_quotes only removes matching outer quotes" {
  assert_eq(@config.strip_quotes("\"value\""), "value")
  assert_eq(@config.strip_quotes("'value'"), "value")
  assert_eq(@config.strip_quotes("\"value'"), "\"value'")
  assert_eq(@config.strip_quotes("value"), "value")
}

///|
test "parse_positive_int rejects zero, signs and junk" {
  assert_eq(@config.parse_positive_int("16"), Some(16))
  assert_eq(@config.parse_positive_int(" 4 "), Some(4))
  assert_eq(@config.parse_positive_int("0"), None)
  assert_eq(@config.parse_positive_int("-1"), None)
  assert_eq(@config.parse_positive_int("4x"), None)
  assert_eq(@config.parse_positive_int(""), None)
}

///|
test "choose_root follows explicit, local, then user order" {
  let cwd = "C:/work"
  let home = "C:/Users/test"
  assert_eq(
    @config.choose_root(cwd, home, Some("~/custom"), true, true),
    "C:/Users/test/custom",
  )
  assert_eq(
    @config.choose_root(cwd, home, None, true, true),
    "C:/work/.media_pilot",
  )
  assert_eq(
    @config.choose_root(cwd, home, None, false, true),
    "C:/Users/test/.media_pilot",
  )
  assert_eq(
    @config.choose_root(cwd, home, None, false, false),
    "C:/work/.media_pilot",
  )
}

///|
test "candidate_files keeps local config ahead of user config" {
  let paths = @config.candidate_files("C:/Users/test", "C:/work/.media_pilot")
  assert_eq(paths.length(), 2)
  assert_eq(paths[0], "C:/work/.media_pilot/config.env")
  assert_eq(paths[1], "C:/Users/test/.media_pilot/config.env")
}

///|
async test "load_from reads the local config root" {
  let base = @fs.tmpdir(prefix="mediapilot-config-")
  let cwd = @config.join_path(base, "work")
  let home = @config.join_path(base, "home")
  let local_root = @config.join_path(cwd, @config.config_directory_name)
  let user_root = @config.join_path(home, @config.config_directory_name)
  @fs.mkdir(local_root, recursive=true, allow_exist=true)
  @fs.mkdir(user_root, recursive=true, allow_exist=true)
  @fs.write_text(
    @config.join_path(local_root, @config.config_file_name),
    "TEST_LOCAL_VALUE=\"from local\"\n",
  )
  @fs.write_text(
    @config.join_path(user_root, @config.config_file_name),
    "TEST_LOCAL_VALUE=\"from home\"\nTEST_HOME_ONLY=\"home only\"\n",
  )
  let loaded = @config.load_from(cwd, home, None)
  assert_eq(loaded.root, local_root)
  assert_eq(loaded.files, [
    @config.join_path(local_root, @config.config_file_name),
    @config.join_path(user_root, @config.config_file_name),
  ])
  assert_eq(loaded.get("TEST_LOCAL_VALUE"), Some("from local"))
  assert_eq(loaded.get("TEST_HOME_ONLY"), Some("home only"))
  @fs.rmdir(base, recursive=true, allow_missing=true)
}
