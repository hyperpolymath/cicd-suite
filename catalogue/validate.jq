# SPDX-License-Identifier: MPL-2.0
# Reviewed metadata structure only; not a proof of gate behaviour.
def text: type == "string" and test("\\S") and (test("[\\x00-\\x1f]") | not);
def ident: text and test("^[a-z][a-z0-9-]*$");
def is_unique: length == (unique | length);
. as $all |
(type == "object") and
(keys == ["capabilities", "clades", "schema_version"]) and
(.schema_version == 1) and
(.clades | type == "array" and length > 0) and
all(.clades[]; (keys == ["id", "summary", "title"]) and all(.[]; text) and (.id | ident)) and
([.clades[].id] | is_unique) and
(.capabilities | type == "array" and length > 0) and
all(.capabilities[];
  . as $e |
  (["id", "clade", "status", "nature", "title", "summary", "limitations", "path"] - keys | length == 0) and
  (keys - ["id", "clade", "status", "nature", "title", "summary", "limitations", "path", "workflow", "template"] | length == 0) and
  all(.[]; text) and
  (.id | ident) and
  ($all.clades | map(.id) | index($e.clade) != null) and
  (["enforcing", "tool-dependent", "advisory", "stub"] | index($e.status) != null) and
  (["scanner", "receipt-verifier", "policy-gate", "validator", "build-test", "proof-executor", "integration", "advisory", "placeholder"] | index($e.nature) != null) and
  ((.status == "stub") == (.nature == "placeholder")) and
  (.path == ("actions/" + .id + "-check/action.yml")) and
  ((has("workflow") | not) or (.workflow | test("^\\.github/workflows/[a-zA-Z0-9_-]+\\.yml$"))) and
  ((has("template") | not) or (.template | test("^templates/[a-zA-Z0-9_-]+\\.yml$")))
) and
([.capabilities[].id] | is_unique) and
([.capabilities[].path] | is_unique) and
(([.capabilities[].clade] | unique | sort) == ([.clades[].id] | sort))
