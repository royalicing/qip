MK_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

$(MK_DIR)countries.sqlite: $(MK_DIR)countries.sql
	sqlite3 $(MK_DIR)countries.sqlite < $(MK_DIR)countries.sql
