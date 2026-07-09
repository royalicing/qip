MK_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

SQLITE_GENERATED_FIXTURES := countries products albums-tablepk kv-without-rowid wal-mode utf16

define SQLITE_FIXTURE_RULE
$(MK_DIR)$(1).sqlite: $(MK_DIR)$(1).sql
	rm -f $(MK_DIR)$(1).sqlite
	sqlite3 $(MK_DIR)$(1).sqlite < $(MK_DIR)$(1).sql
endef

$(foreach f,$(SQLITE_GENERATED_FIXTURES),$(eval $(call SQLITE_FIXTURE_RULE,$(f))))

sqlite-fixtures: $(foreach f,$(SQLITE_GENERATED_FIXTURES),$(MK_DIR)$(f).sqlite)
.PHONY: sqlite-fixtures
