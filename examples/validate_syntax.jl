using YAMLEvents

# A configuration loader can accept only the YAML syntax it handles explicitly.
const CONFIG_POLICY = SyntaxPolicy(document_count = 1, allow_flow_collections = false,
                                   allow_anchors = false, allow_aliases = false,
                                   allow_tags = false, allow_unknown_directives = false,
                                   allow_merge_keys = false, allow_duplicate_keys = false)

valid_source = """
service:
  name: api
  enabled: true
"""

summary = validate_events(parse_events(valid_source); policy = CONFIG_POLICY)
println("Validated ", summary.document_count, " YAML document.")

duplicate_source = """
service:
  name: api
  name: worker
"""

try
    validate_events(parse_events(duplicate_source); policy = CONFIG_POLICY)
catch exception
    if exception isa DuplicateKeyError
        println("Rejected duplicate key ", repr(exception.key), " at ", exception.mark,
                "; first defined at ", exception.first_mark, ".")
    else
        rethrow()
    end
end
