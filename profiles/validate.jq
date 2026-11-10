# SPDX-License-Identifier: MPL-2.0
# Structural proposal validation. No runtime verdict or policy admission.
def exact($fields): type == "object" and (keys == ($fields | sort));
def unique_items: length == (unique | length);
def clean_string: type == "string" and (explode | all(. >= 32 and . != 127));
def ident: clean_string and test("^[a-z][a-z0-9-]*$");
def repository: clean_string and test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$");
# A lexical slot only; the future executor must also reject symlink escapes.
def relative_path:
  clean_string and
  (. == "." or (test("^[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_][A-Za-z0-9_.-]*)*$") and
    (split("/") | all(. != "." and . != ".."))));
def version: clean_string and test("^[0-9]+[.][0-9]+([.][0-9]+)?$");
def nonempty_array: type == "array" and length > 0 and unique_items;
def slots($adapter):
  (.root | relative_path) and
  if $adapter == "docs-data" then
    (.documents | nonempty_array and all(.[]; relative_path and . != "."))
  elif $adapter == "julia-pkg" then
    (.julia_versions | nonempty_array and all(.[]; version))
  elif $adapter == "rust-cargo" then (.msrv | version)
  else false end;
def valid_mothers:
  exact(["schema_version", "stage", "mothers"]) and .schema_version == 1 and .stage == "proposal" and
  (.mothers | nonempty_array) and ([.mothers[].id] | unique_items) and
  all(.mothers[];
    exact(["id", "adapter", "required_capabilities", "required_slots", "adapter_state"]) and
    (.id | ident) and
    (.adapter as $a | ["docs-data", "julia-pkg", "rust-cargo"] | index($a) != null) and
    (.adapter_state as $s | ["unimplemented", "unqualified"] | index($s) != null) and
    (.required_capabilities | nonempty_array and all(.[]; ident)) and
    (.required_slots == (if .adapter == "docs-data" then ["root", "documents"]
      elif .adapter == "julia-pkg" then ["root", "julia_versions"] else ["root", "msrv"] end)));
def valid_profile($mothers; $catalogue):
  . as $p |
  ([$mothers.mothers[] | select(.id == $p.mother)]) as $matches |
  exact(["schema_version", "stage", "repository", "mother", "lifecycles", "capabilities", "slots"]) and
  .schema_version == 1 and .stage == "proposal" and
  (.repository | repository) and
  (.mother | ident) and
  (.lifecycles | type == "array" and (sort == ["maintenance", "validate"])) and
  (.capabilities | nonempty_array) and
  ([.capabilities[].id] | unique_items) and
  all(.capabilities[];
    exact(["id", "obligation"]) and (.id | ident) and
    (.obligation == "required" or .obligation == "advisory") and
    . as $requirement |
    ([$catalogue.capabilities[] | select(.id == $requirement.id)] | length == 1) and
    ([$catalogue.capabilities[] | select(.id == $requirement.id)][0] |
      .status != "stub" and
      ($requirement.obligation != "required" or .status == "enforcing" or .status == "tool-dependent"))) and
  ($matches | length == 1) and
  ($matches[0] as $mother |
    ($p.slots | exact($mother.required_slots) and slots($mother.adapter)) and
    all($mother.required_capabilities[];
      . as $id | any($p.capabilities[]; .id == $id and .obligation == "required")));
# Slurped inputs must each contain exactly one JSON document.
($mothers | length == 1) and ($catalogue | length == 1) and
($mothers[0] | valid_mothers) and
(length == 1) and (.[0] | valid_profile($mothers[0]; $catalogue[0]))
