" Dim the box-drawing border/separator rows and pipe delimiters that
" mysql/psql print by default, so the actual data stands out instead of
" the ascii table frame.
syntax match DbUiTableBorder /^\s*[+-][+-]*\s*$/
syntax match DbUiColumnSep /|/

highlight default link DbUiTableBorder Comment
highlight default link DbUiColumnSep Comment
