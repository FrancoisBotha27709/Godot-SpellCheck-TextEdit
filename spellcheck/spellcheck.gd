@tool
extends EditorPlugin

const CUSTOM_NODE_NAME := "SpellcheckTextEdit"
const SCRIPT_PATH := "res://addons/spellcheck/spellcheck_text_edit.gd"

func _enter_tree():
	add_custom_type(
		CUSTOM_NODE_NAME,
		"TextEdit",
		preload(SCRIPT_PATH),
		null
	)

func _exit_tree():
	remove_custom_type(CUSTOM_NODE_NAME)
