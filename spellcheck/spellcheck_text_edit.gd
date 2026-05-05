@tool
extends TextEdit

var dictionary := {}
var prefix_index := {}

const PREFIX_SIZE := 3
const MAX_DISTANCE := 2
const MAX_SUGGESTIONS := 5

const ADD_TO_DICTIONARY_ID := 999999
const DICTIONARY_PATH := "user://dictionary.txt"
const SOURCE_DICTIONARY := "res://addons/spellcheck/dictionary.txt"

var popup: PopupMenu
var error_ranges := []
var line_offsets := []

var _time_accum := 0.0
const REDRAW_INTERVAL := 1.0

var _popup_context_word := ""

func _ready() -> void:
	if Engine.is_editor_hint() and not get_tree().edited_scene_root:
		return

	_ensure_dictionary_file()
	_load_dictionary()

	connect("text_changed", _on_text_changed)
	connect("gui_input", _on_gui_input)

	_setup_popup()
	set_process(true)

func _process(delta: float) -> void:
	_time_accum += delta
	if _time_accum >= REDRAW_INTERVAL:
		_time_accum = 0.0
		queue_redraw()

#region Dictionary creation/Setup

func _normalize_word(w: String) -> String:
	return w.to_lower().strip_edges()

func _ensure_dictionary_file() -> void:
	if FileAccess.file_exists(DICTIONARY_PATH):
		return

	var src = FileAccess.open(SOURCE_DICTIONARY, FileAccess.READ)
	if src == null:
		push_error("Missing source dictionary")
		return

	var dst = FileAccess.open(DICTIONARY_PATH, FileAccess.WRITE)
	if dst == null:
		push_error("Cannot create user dictionary")
		return

	while not src.eof_reached():
		var line = _normalize_word(src.get_line())
		if line != "":
			dst.store_line(line)

	src.close()
	dst.close()

func _load_dictionary() -> void:
	var file = FileAccess.open(DICTIONARY_PATH, FileAccess.READ)
	if file == null:
		push_error("Dictionary missing")
		return

	while not file.eof_reached():
		var word = _normalize_word(file.get_line())
		if word == "":
			continue
		_register_word(word)

func _register_word(word: String) -> void:
	word = _normalize_word(word)
	dictionary[word] = true

	var prefix = word.substr(0, min(PREFIX_SIZE, word.length()))
	if not prefix_index.has(prefix):
		prefix_index[prefix] = []

	prefix_index[prefix].append(word)

func _save_word(word: String) -> void:
	print("Writing word:", word)
	word = _normalize_word(word)
	if word == "" or dictionary.has(word):
		return

	dictionary[word] = true
	_register_word(word)

	var file = FileAccess.open(DICTIONARY_PATH, FileAccess.READ_WRITE)
	if file == null:
		push_error("Failed to open dictionary for writing")
		return

	file.seek_end()
	file.store_line(word)
	file.close()

func _on_text_changed() -> void:
	_rebuild_line_offsets()
	_check_words()
	queue_redraw()
#endregion

#region Word check
func _is_valid(word: String) -> bool:
	word = _normalize_word(word)
	if word.length() <= 1:
		return true
	return dictionary.has(word)

func _check_words() -> void:
	error_ranges.clear()

	var regex = RegEx.new()
	regex.compile("[A-Za-z']+")

	for m in regex.search_all(text):
		var word = _normalize_word(m.get_string())

		if not _is_valid(word):
			error_ranges.append({
				"start": m.get_start(),
				"end": m.get_end()
			})
#endregion

#region Input
func _on_gui_input(event):
	if event is InputEventMouseButton and event.pressed:
		var word_info = _get_word_at_index(get_caret_column())
		if word_info.is_empty():
			return

		var word = _normalize_word(word_info["word"])
		if dictionary.has(word):
			return

		_show_suggestions(word, word_info)

func _get_word_at_index(index: int) -> Dictionary:
	var regex = RegEx.new()
	regex.compile("[A-Za-z']+")

	for m in regex.search_all(text):
		if index >= m.get_start() and index <= m.get_end():
			return {
				"word": m.get_string(),
				"start": m.get_start(),
				"end": m.get_end()
			}

	return {}
#endregion

#region Popup

func _setup_popup():
	popup = PopupMenu.new()
	add_child(popup)
	popup.id_pressed.connect(_on_popup_selected)

func _show_suggestions(word: String, info: Dictionary) -> void:
	popup.clear()

	_popup_context_word = word

	var suggestions = _find_suggestions(word)

	for i in range(suggestions.size()):
		popup.add_item(suggestions[i], i)
		popup.set_item_metadata(i, suggestions[i])

	if suggestions.size() > 0:
		popup.add_separator()

	popup.add_item("Add to dictionary", ADD_TO_DICTIONARY_ID)

	var pos = get_caret_draw_pos()
	popup.position = global_position + pos + Vector2(10, 20)
	popup.popup()

func _on_popup_selected(id: int) -> void:
	print("POPUP CLICKED ID:", id)
	var word_info = _get_word_at_index(get_caret_column())
	if word_info.is_empty():
		return

	var start = word_info["start"]
	var end = word_info["end"]

	# ADD TO DICTIONARY
	if id == ADD_TO_DICTIONARY_ID:
		var word = _normalize_word(_popup_context_word)

		if word != "":
			_save_word(word)

		_check_words()
		queue_redraw()
		return

	var suggestion = popup.get_item_metadata(id)
	if suggestion == null:
		return

	# prevent recursive corruption
	set_block_signals(true)

	var before = text.substr(0, start)
	var after = text.substr(end, text.length() - end)

	text = before + suggestion + after

	set_caret_column(start + suggestion.length())

	set_block_signals(false)

	_check_words()
	queue_redraw()

func _find_suggestions(word: String) -> Array:
	word = _normalize_word(word)

	var prefix = word.substr(0, min(PREFIX_SIZE, word.length()))
	if not prefix_index.has(prefix):
		return []

	var results := []

	for c in prefix_index[prefix]:
		var d = _levenshtein(word, c)
		if d <= MAX_DISTANCE:
			results.append({ "word": c, "dist": d })

	results.sort_custom(func(a, b): return a["dist"] < b["dist"])

	var out := []
	for i in range(min(MAX_SUGGESTIONS, results.size())):
		out.append(results[i]["word"])

	return out
#endregion

#region Levenshtein
func _levenshtein(a: String, b: String) -> int:
	var n = a.length()
	var m = b.length()

	var prev = []
	for j in range(m + 1):
		prev.append(j)

	for i in range(1, n + 1):
		var curr = [i]

		for j in range(1, m + 1):
			var cost = 0 if a[i - 1] == b[j - 1] else 1
			curr.append(min(
				prev[j] + 1,
				curr[j - 1] + 1,
				prev[j - 1] + cost
			))

		prev = curr

	return prev[m]
#endregion

#region Drawing STUFF
func _rebuild_line_offsets() -> void:
	line_offsets.clear()

	var running := 0
	var lines = text.split("\n")

	for i in range(lines.size()):
		line_offsets.append(running)
		running += lines[i].length() + 1


func _line_of_index(index: int) -> int:
	for i in range(line_offsets.size()):
		if i == line_offsets.size() - 1:
			return i
		if index < line_offsets[i + 1]:
			return i
	return 0


func _index_to_pos(index: int) -> Vector2:
	if line_offsets.is_empty():
		_rebuild_line_offsets()

	var line = _line_of_index(index)
	var col = index - line_offsets[line]

	var font = get_theme_font("font")
	if font == null:
		return Vector2.ZERO

	var line_text = get_line(line)
	var x = font.get_string_size(line_text.substr(0, min(col, line_text.length()))).x
	var y = (line + 1) * get_line_height()

	return Vector2(x, y)


func _draw():
	for r in error_ranges:
		draw_line(
			_index_to_pos(r["start"]),
			_index_to_pos(r["end"]),
			Color.RED,
			2
		)
#endregion
