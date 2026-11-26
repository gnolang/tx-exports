package formula

// Function describes one function for people.
type Function struct {
	Group string
	Usage string // "NAME(arguments)"
	Help  string
	// Example evaluates to Result when A1:A4 hold 4, 8, 15, 16 and B1:B4 hold
	// ale, mead, ale, rum. Functions that read the chain have no example.
	Example, Result string
}

// Functions lists every function a formula can call.
func Functions() []Function {
	return []Function{
		{"Totals", "SUM(values...)", "Adds numbers. Text and blanks in a range are skipped.", "=SUM(A1:A4)", "43"},
		{"Totals", "PRODUCT(values...)", "Multiplies numbers.", "=PRODUCT(A1:A2)", "32"},
		{"Totals", "AVERAGE(values...)", "Mean of the numbers.", "=AVERAGE(A1:A4)", "10.75"},
		{"Totals", "MEDIAN(range)", "Middle number.", "=MEDIAN(A1:A4)", "11.5"},
		{"Totals", "MIN(values...)", "Smallest number.", "=MIN(A1:A4)", "4"},
		{"Totals", "MAX(values...)", "Largest number.", "=MAX(A1:A4)", "16"},
		{"Totals", "LARGE(range, k)", "The k-th largest number.", "=LARGE(A1:A4, 2)", "15"},
		{"Totals", "SMALL(range, k)", "The k-th smallest number.", "=SMALL(A1:A4, 2)", "8"},
		{"Totals", "RANK(x, range, [ascending])", "Place of x among the numbers, the largest being 1.", "=RANK(15, A1:A4)", "2"},
		{"Totals", "COUNT(values...)", "How many numbers.", "=COUNT(A1:B4)", "4"},
		{"Totals", "COUNTA(values...)", "How many cells are filled.", "=COUNTA(A1:B4)", "8"},
		{"Totals", "COUNTBLANK(range)", "How many cells are blank.", "=COUNTBLANK(A1:A6)", "2"},
		{"Totals", "SUMPRODUCT(ranges...)", "Sum of the products of matching cells.", "=SUMPRODUCT(A1:A2, A3:A4)", "188"},

		{"Conditions", "IF(test, then, [else])", "Chooses by a test. Only the chosen part is evaluated.", "=IF(A1>3, \"yes\", \"no\")", "yes"},
		{"Conditions", "IFS(test, value, ...)", "Value of the first test that holds.", "=IFS(A1>9, \"big\", A1>3, \"fair\")", "fair"},
		{"Conditions", "IFERROR(value, fallback)", "Replaces an error.", "=IFERROR(A1/0, \"none\")", "none"},
		{"Conditions", "CHOOSE(n, values...)", "The n-th value.", "=CHOOSE(2, \"a\", \"b\")", "b"},
		{"Conditions", "AND(tests...)", "Whether all tests hold.", "=AND(A1>3, A2>9)", "FALSE"},
		{"Conditions", "OR(tests...)", "Whether any test holds.", "=OR(A1>3, A2>9)", "TRUE"},
		{"Conditions", "NOT(test)", "The opposite.", "=NOT(A1>3)", "FALSE"},
		{"Conditions", "COUNTIF(range, condition)", "How many cells meet a condition such as 5, \"ale\" or \">=10\".", "=COUNTIF(B1:B4, \"ale\")", "2"},
		{"Conditions", "SUMIF(range, condition, [amounts])", "Adds where a condition is met.", "=SUMIF(B1:B4, \"ale\", A1:A4)", "19"},
		{"Conditions", "AVERAGEIF(range, condition, [amounts])", "Mean where a condition is met.", "=AVERAGEIF(B1:B4, \"ale\", A1:A4)", "9.5"},
		{"Conditions", "ISERROR(value)", "Whether it is an error.", "=ISERROR(1/0)", "TRUE"},
		{"Conditions", "ISBLANK(cell)", "Whether it is blank.", "=ISBLANK(A9)", "TRUE"},
		{"Conditions", "ISNUMBER(value)", "Whether it is a number.", "=ISNUMBER(B1)", "FALSE"},
		{"Conditions", "ISTEXT(value)", "Whether it is text.", "=ISTEXT(B1)", "TRUE"},

		{"Lookup", "XLOOKUP(key, keys, values, [fallback])", "The value next to the first matching key. Exact match, ignoring case.", "=XLOOKUP(\"rum\", B1:B4, A1:A4)", "16"},
		{"Lookup", "MATCH(key, range, 0)", "Position of the first exact match.", "=MATCH(\"mead\", B1:B4, 0)", "2"},
		{"Lookup", "INDEX(range, row, [column])", "The cell at a position.", "=INDEX(A1:B4, 3, 1)", "15"},
		{"Lookup", "ROW([cell])", "Row number.", "=ROW(B7)", "7"},
		{"Lookup", "COLUMN([cell])", "Column number.", "=COLUMN(B7)", "2"},

		{"Math", "ROUND(x, [places])", "Rounds, halves away from zero.", "=ROUND(2.345, 2)", "2.35"},
		{"Math", "ROUNDUP(x, [places])", "Rounds away from zero.", "=ROUNDUP(2.341, 2)", "2.35"},
		{"Math", "ROUNDDOWN(x, [places])", "Rounds toward zero.", "=ROUNDDOWN(2.349, 2)", "2.34"},
		{"Math", "INT(x)", "Largest whole number not above x.", "=INT(-2.5)", "-3"},
		{"Math", "MOD(x, y)", "Remainder, with the sign of y.", "=MOD(-7, 3)", "2"},
		{"Math", "ABS(x)", "Size without sign.", "=ABS(-4)", "4"},
		{"Math", "SIGN(x)", "1, 0 or -1.", "=SIGN(-4)", "-1"},
		{"Math", "SQRT(x)", "Square root.", "=SQRT(2)", "1.414214"},
		{"Math", "POWER(x, n)", "Same as x^n, for whole n from -1000 to 1000.", "=POWER(2, 10)", "1024"},

		{"Text", "CONCAT(values...)", "Joins values.", "=CONCAT(B1, \"-\", A1)", "ale-4"},
		{"Text", "TEXTJOIN(separator, skip_blank, values...)", "Joins values with a separator.", "=TEXTJOIN(\"+\", TRUE, A1:A4)", "4+8+15+16"},
		{"Text", "FIXED(x, [places], [plain])", "Number as text, with thousands separators unless plain.", "=FIXED(1234.5, 2)", "1,234.50"},
		{"Text", "LEN(text)", "How many characters.", "=LEN(B2)", "4"},
		{"Text", "LEFT(text, [n])", "First characters.", "=LEFT(B2, 2)", "me"},
		{"Text", "RIGHT(text, [n])", "Last characters.", "=RIGHT(B2, 2)", "ad"},
		{"Text", "MID(text, start, n)", "Characters from a position.", "=MID(B2, 2, 2)", "ea"},
		{"Text", "FIND(part, text, [start])", "Position of a part.", "=FIND(\"a\", B2)", "3"},
		{"Text", "SUBSTITUTE(text, old, new)", "Replaces parts.", "=SUBSTITUTE(B2, \"m\", \"b\")", "bead"},
		{"Text", "REPT(text, n)", "Repeats text.", "=REPT(B4, 2)", "rumrum"},
		{"Text", "UPPER(text)", "In capitals.", "=UPPER(B1)", "ALE"},
		{"Text", "LOWER(text)", "In small letters.", "=LOWER(\"ALE\")", "ale"},
		{"Text", "TRIM(text)", "Without extra spaces.", "=TRIM(\" a  b \")", "a b"},
		{"Text", "EXACT(a, b)", "Whether two texts are the same, case included.", "=EXACT(B1, \"ALE\")", "FALSE"},
		{"Text", "VALUE(text)", "Text as a number.", "=VALUE(\"12.5\")", "12.5"},

		{"Pictures", "SPARK(range)", "A line of blocks, one per number.", "=SPARK(A1:A4)", "▁▃▇█"},
		{"Pictures", "BAR(x, max, [width])", "A bar of blocks.", "=BAR(A1, 16, 8)", "██░░░░░░"},

		{"Chain", "BALANCE(address)", "GNOT held by an address, right now.", "", ""},
		{"Chain", "TOKEN(id, address)", "GRC20 tokens held by an address. The id is the token's key in grc20reg.", "", ""},
		{"Chain", "EDITOR(cell)", "Address that wrote a cell.", "", ""},
		{"Chain", "EDITED(cell)", "Block height at which a cell was written.", "", ""},
		{"Chain", "OWNER()", "Address of the sheet's owner.", "", ""},
		{"Chain", "HEIGHT()", "Block height.", "", ""},
		{"Chain", "NOW()", "Block time, in seconds since 1970.", "", ""},
	}
}
