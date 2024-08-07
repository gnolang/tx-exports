package ujson

import (
	"std"
	"strconv"
	"strings"
	"time"

	"gno.land/p/demo/avl"
	"gno.land/p/demo/users"
)

// https://stackoverflow.com/a/4150626
const whitespaces = " \t\n\r"

type FromJSONAble interface {
	FromJSON(ast *JSONASTNode)
}

// does not work for slices, use ast exploration instead
func (ast *JSONASTNode) ParseAny(ptr interface{}) {
	switch ptr.(type) {
	case *std.Address:
		*ptr.(*std.Address) = std.Address(ParseString(ast.Value))
	case **avl.Tree:
		panic("*avl.Tree not implemented, there is no way to know the type of the tree values, use a custom parser instead")
	case *avl.Tree:
		panic("avl.Tree not implemented, there is no way to know the type of the tree values, use a custom parser instead")
	case *string:
		if ast.Kind != JSONKindValue {
			panic("not a value")
		}
		if ast.ValueKind != JSONTokenKindString {
			panic("not a string")
		}
		*ptr.(*string) = ParseString(ast.Value)
	case *uint64:
		if ast.Kind != JSONKindValue {
			panic("not a value")
		}
		if ast.ValueKind != JSONTokenKindNumber {
			panic("not a number")
		}
		*ptr.(*uint64) = ParseUint64(ast.Value)
	case *uint32:
		if ast.Kind != JSONKindValue {
			panic("not a value")
		}
		if ast.ValueKind != JSONTokenKindNumber {
			panic("not a number")
		}
		*ptr.(*uint32) = uint32(ParseUint64(ast.Value))
	case *uint:
		if ast.Kind != JSONKindValue {
			panic("not a value")
		}
		if ast.ValueKind != JSONTokenKindNumber {
			panic("not a number")
		}
		*ptr.(*uint) = uint(ParseUint64(ast.Value))
	case *int64:
		if ast.Kind != JSONKindValue {
			panic("not a value")
		}
		if ast.ValueKind != JSONTokenKindNumber {
			panic("not a number")
		}
		*ptr.(*int64) = ParseInt64(ast.Value)
	case *int32:
		if ast.Kind != JSONKindValue {
			panic("not a value")
		}
		if ast.ValueKind != JSONTokenKindNumber {
			panic("not a number")
		}
		*ptr.(*int32) = int32(ParseInt64(ast.Value))
	case *int:
		if ast.Kind != JSONKindValue {
			panic("not a value")
		}
		if ast.ValueKind != JSONTokenKindNumber {
			panic("not a number")
		}
		*ptr.(*int) = int(ParseInt64(ast.Value))
	case *float64:
		panic("float64 not implemented")
	case *float32:
		panic("float32 not implemented")
	case *bool:
		if ast.Kind != JSONKindValue {
			panic("not a value")
		}
		if ast.ValueKind != JSONTokenKindTrue && ast.ValueKind != JSONTokenKindFalse {
			panic("not a bool")
		}
		*ptr.(*bool) = ast.ValueKind == JSONTokenKindTrue
	case *FromJSONAble:
		(*(ptr.(*FromJSONAble))).FromJSON(ast)
	case FromJSONAble:
		ptr.(FromJSONAble).FromJSON(ast)
	case **JSONASTNode:
		*ptr.(**JSONASTNode) = ast
	case *time.Time:
		ast.ParseTime(ptr.(*time.Time))
	case *time.Duration:
		*ptr.(*time.Duration) = time.Duration(ParseInt64(ast.Value))
	case *users.AddressOrName:
		s := ParseString(ast.Value)
		*ptr.(*users.AddressOrName) = users.AddressOrName(s)
	default:
		if ast.Kind == JSONKindValue && ast.ValueKind == JSONTokenKindNull {
			// *ptr.(*interface{}) = nil // TODO: handle nil
			return
		}
		panic("type not defined for `" + ast.String() + "`")
	}
}

// loosely ported from https://cs.opensource.google/go/go/+/master:src/time/time.go;l=1370?q=appendStrictRFC3339&ss=go%2Fgo
// it's not a full port since it would require copying lot of utils
func (ast *JSONASTNode) ParseTime(t *time.Time) {
	if ast.Kind != JSONKindValue && ast.ValueKind != JSONTokenKindString {
		panic("time is not a string")
	}
	s := ParseString(ast.Value)
	var err error
	*t, err = time.Parse(time.RFC3339Nano, s)
	if err != nil {
		panic(err)
	}
}

func ParseUint64(s string) uint64 {
	val, err := strconv.Atoi(s)
	if err != nil {
		panic(err)
	}
	return uint64(val)
}

func ParseInt64(s string) int64 {
	val, err := strconv.Atoi(s)
	if err != nil {
		panic(err)
	}
	return int64(val)
}

type ParseKV struct {
	Key          string
	Value        interface{}
	ArrayParser  func(children []*JSONASTNode)
	ObjectParser func(children []*JSONASTKV)
	CustomParser func(node *JSONASTNode)
}

func ParseAny(s string, val interface{}) {
	tokens := tokenize(s)
	if len(tokens) == 0 {
		panic("empty json")
	}
	remainingTokens, ast := parseAST(tokens)
	if len(remainingTokens) > 0 {
		panic("invalid json")
	}
	ast.ParseAny(val)
}

func (ast *JSONASTNode) ParseObject(kv []*ParseKV) {
	if ast.Kind != JSONKindObject {
		panic("not an object")
	}
	for _, elem := range kv {
		for i, child := range ast.ObjectChildren {
			if child.Key == elem.Key {
				if elem.ArrayParser != nil {
					if child.Value.Kind != JSONKindArray {
						panic("not an array")
					}
					elem.ArrayParser(child.Value.ArrayChildren)
				} else if elem.ObjectParser != nil {
					if child.Value.Kind != JSONKindObject {
						panic("not an object")
					}
					elem.ObjectParser(child.Value.ObjectChildren)
				} else if elem.CustomParser != nil {
					elem.CustomParser(child.Value)
				} else {
					child.Value.ParseAny(elem.Value)
				}
				break
			}
			if i == (len(ast.ObjectChildren) - 1) {
				panic("invalid key `" + elem.Key + "` in object `" + ast.String() + "`")
			}
		}
	}
}

func (ast *JSONASTNode) ParseUnion(kv []*ParseKV) interface{} {
	if ast.Kind != JSONKindObject {
		panic("union is not an object")
	}
	if len(ast.ObjectChildren) != 1 {
		panic("union object does not have exactly one field")
	}
	k, node := ast.ObjectChildren[0].Key, ast.ObjectChildren[0].Value
	for _, kv := range kv {
		if kv.Key == k {
			node.ParseAny(kv.Value)
			return kv.Value
		}
	}
	panic("unknown union type") // TODO: expected one of ...
}

func ParseSlice(s string) []*JSONASTNode {
	ast := TokenizeAndParse(s)
	return ast.ParseSlice()
}

func (ast *JSONASTNode) ParseSlice() []*JSONASTNode {
	if ast.Kind != JSONKindArray {
		panic("not an array")
	}
	return ast.ArrayChildren
}

func countWhitespaces(s string) int {
	i := 0
	for i < len(s) {
		if strings.ContainsRune(whitespaces, int32(s[i])) {
			i++
		} else {
			break
		}
	}
	return i
}

func JSONTokensString(tokens []*JSONToken) string {
	s := ""
	for _, token := range tokens {
		s += token.Raw
	}
	return s
}

func (node *JSONASTNode) String() string {
	if node == nil {
		return "nil"
	}
	switch node.Kind {
	case JSONKindValue:
		return node.Value
	case JSONKindArray:
		s := "["
		for i, child := range node.ArrayChildren {
			if i > 0 {
				s += ","
			}
			s += child.String()
		}
		s += "]"
		return s
	case JSONKindObject:
		s := "{"
		for i, child := range node.ObjectChildren {
			if i > 0 {
				s += ","
			}
			s += `"` + child.Key + `":` + child.Value.String()
		}
		s += "}"
		return s
	default:
		panic("invalid json")
	}
}

func TokenizeAndParse(s string) *JSONASTNode {
	tokens := tokenize(s)
	if len(tokens) == 0 {
		panic("empty json")
	}
	remainingTokens, ast := parseAST(tokens)
	if len(remainingTokens) > 0 {
		panic("invalid json")
	}
	return ast
}

func parseAST(tokens []*JSONToken) (tkn []*JSONToken, tree *JSONASTNode) {
	if len(tokens) == 0 {
		panic("empty json")
	}

	switch tokens[0].Kind {

	case JSONTokenKindString:
		return tokens[1:], &JSONASTNode{Kind: JSONKindValue, ValueKind: tokens[0].Kind, Value: tokens[0].Raw}
	case JSONTokenKindNumber:
		return tokens[1:], &JSONASTNode{Kind: JSONKindValue, ValueKind: tokens[0].Kind, Value: tokens[0].Raw}
	case JSONTokenKindTrue:
		return tokens[1:], &JSONASTNode{Kind: JSONKindValue, ValueKind: tokens[0].Kind, Value: tokens[0].Raw}
	case JSONTokenKindFalse:
		return tokens[1:], &JSONASTNode{Kind: JSONKindValue, ValueKind: tokens[0].Kind, Value: tokens[0].Raw}
	case JSONTokenKindNull:
		return tokens[1:], &JSONASTNode{Kind: JSONKindValue, ValueKind: tokens[0].Kind, Value: tokens[0].Raw}

	case JSONTokenKindOpenArray:
		arrayChildren := []*JSONASTNode{}
		tokens = tokens[1:]
		for len(tokens) > 0 {
			if tokens[0].Kind == JSONTokenKindCloseArray {
				return tokens[1:], &JSONASTNode{Kind: JSONKindArray, ArrayChildren: arrayChildren}
			}
			var child *JSONASTNode
			tokens, child = parseAST(tokens)
			arrayChildren = append(arrayChildren, child)
			if len(tokens) == 0 {
				panic("exepected more tokens in array")
			}
			if tokens[0].Kind == JSONTokenKindComma {
				tokens = tokens[1:]
			} else if tokens[0].Kind == JSONTokenKindCloseArray {
				return tokens[1:], &JSONASTNode{Kind: JSONKindArray, ArrayChildren: arrayChildren}
			} else {
				panic("unexpected token in array after value `" + tokens[0].Raw + "`")
			}
		}

	case JSONTokenKindOpenObject:
		objectChildren := []*JSONASTKV{}
		if len(tokens) < 2 {
			panic("objects must have at least 2 tokens")
		}
		tokens = tokens[1:]
		for len(tokens) > 0 {
			if tokens[0].Kind == JSONTokenKindCloseObject {
				return tokens[1:], &JSONASTNode{Kind: JSONKindObject, ObjectChildren: objectChildren}
			}
			if tokens[0].Kind != JSONTokenKindString {
				panic("invalid json")
			}
			key := tokens[0].Raw
			tokens = tokens[1:]
			if len(tokens) == 0 {
				panic("exepected more tokens in object")
			}
			if tokens[0].Kind != JSONTokenKindColon {
				panic("expected :")
			}
			tokens = tokens[1:]
			if len(tokens) == 0 {
				panic("exepected more tokens in object after :")
			}
			var value *JSONASTNode
			tokens, value = parseAST(tokens)
			objectChildren = append(objectChildren, &JSONASTKV{Key: ParseString(key), Value: value})
			if len(tokens) == 0 {
				panic("exepected more tokens in object after value")
			}
			if tokens[0].Kind == JSONTokenKindComma {
				tokens = tokens[1:]
			} else if tokens[0].Kind == JSONTokenKindCloseObject {
				return tokens[1:], &JSONASTNode{Kind: JSONKindObject, ObjectChildren: objectChildren}
			} else {
				panic("unexpected token in object after value `" + tokens[0].Raw + "`")
			}
		}

	default:
		panic("unexpected token `" + tokens[0].Raw + "`")
	}

	return
}

func tokenize(s string) []*JSONToken {
	tokens := []*JSONToken{}
	for len(s) > 0 {
		var token *JSONToken
		s, token = tokenizeOne(s)
		if token.Kind != JSONTokenKindSpaces {
			tokens = append(tokens, token)
		}
	}
	return tokens
}

func tokenizeOne(s string) (string, *JSONToken) {
	if len(s) == 0 {
		panic("invalid token")
	}
	spacesCount := countWhitespaces(s)
	if spacesCount > 0 {
		spaces := s[:spacesCount]
		return s[spacesCount:], &JSONToken{Kind: JSONTokenKindSpaces, Raw: spaces}
	}
	switch s[0] {
	case '"':
		return parseStringToken(s)
	case 't':
		return parseKeyword(s, "true", JSONTokenKindTrue)
	case 'f':
		return parseKeyword(s, "false", JSONTokenKindFalse)
	case 'n':
		return parseKeyword(s, "null", JSONTokenKindNull)
	case '{':
		return s[1:], &JSONToken{Kind: JSONTokenKindOpenObject, Raw: "{"}
	case '[':
		return s[1:], &JSONToken{Kind: JSONTokenKindOpenArray, Raw: "["}
	case ':':
		return s[1:], &JSONToken{Kind: JSONTokenKindColon, Raw: ":"}
	case ',':
		return s[1:], &JSONToken{Kind: JSONTokenKindComma, Raw: ","}
	case ']':
		return s[1:], &JSONToken{Kind: JSONTokenKindCloseArray, Raw: "]"}
	case '}':
		return s[1:], &JSONToken{Kind: JSONTokenKindCloseObject, Raw: "}"}
	default:
		return parseNumber(s)
	}
}

func parseKeyword(s string, keyword string, kind JSONTokenKind) (string, *JSONToken) {
	if len(s) < len(keyword) {
		panic("invalid keyword")
	}
	if s[:len(keyword)] != keyword {
		panic("invalid keyword")
	}
	return s[len(keyword):], &JSONToken{Kind: kind, Raw: keyword}
}

func parseStringToken(s string) (string, *JSONToken) {
	if (len(s) < 2) || (s[0] != '"') {
		panic("invalid string")
	}
	quote := false
	for i := 1; i < len(s); i++ {
		if !quote && s[i] == '\\' {
			quote = true
			continue
		}
		if !quote && s[i] == '"' {
			return s[i+1:], &JSONToken{Kind: JSONTokenKindString, Raw: s[:i+1]}
		}
		quote = false
	}
	panic("invalid string")
}

// copiloted
func parseNumber(s string) (string, *JSONToken) {
	if len(s) == 0 {
		panic("invalid number")
	}
	i := 0
	if s[i] == '-' {
		i++
	}
	if i == len(s) {
		panic("invalid number")
	}
	if s[i] == '0' {
		i++
	} else if ('1' <= s[i]) && (s[i] <= '9') {
		i++
		for (i < len(s)) && ('0' <= s[i]) && (s[i] <= '9') {
			i++
		}
	} else {
		panic("invalid number")
	}
	if i == len(s) {
		return s[i:], &JSONToken{Kind: JSONTokenKindNumber, Raw: s}
	}
	if s[i] == '.' {
		i++
		if i == len(s) {
			panic("invalid number")
		}
		if ('0' <= s[i]) && (s[i] <= '9') {
			i++
			for (i < len(s)) && ('0' <= s[i]) && (s[i] <= '9') {
				i++
			}
		} else {
			panic("invalid number")
		}
	}
	if i == len(s) {
		return s[i:], &JSONToken{Kind: JSONTokenKindNumber, Raw: s}
	}
	if (s[i] == 'e') || (s[i] == 'E') {
		i++
		if i == len(s) {
			panic("invalid number")
		}
		if (s[i] == '+') || (s[i] == '-') {
			i++
		}
		if i == len(s) {
			panic("invalid number")
		}
		if ('0' <= s[i]) && (s[i] <= '9') {
			i++
			for (i < len(s)) && ('0' <= s[i]) && (s[i] <= '9') {
				i++
			}
		} else {
			panic("invalid number")
		}
	}
	return s[i:], &JSONToken{Kind: JSONTokenKindNumber, Raw: s[:i]}
}

type JSONTokenKind int

type JSONKind int

const (
	JSONKindUnknown JSONKind = iota
	JSONKindValue
	JSONKindObject
	JSONKindArray
)

type JSONASTNode struct {
	Kind           JSONKind
	ArrayChildren  []*JSONASTNode
	ObjectChildren []*JSONASTKV
	ValueKind      JSONTokenKind
	Value          string
}

type JSONASTKV struct {
	Key   string
	Value *JSONASTNode
}

const (
	JSONTokenKindUnknown JSONTokenKind = iota
	JSONTokenKindString
	JSONTokenKindNumber
	JSONTokenKindTrue
	JSONTokenKindFalse
	JSONTokenKindSpaces
	JSONTokenKindComma
	JSONTokenKindColon
	JSONTokenKindOpenArray
	JSONTokenKindCloseArray
	JSONTokenKindOpenObject
	JSONTokenKindCloseObject
	JSONTokenKindNull
)

func (k JSONTokenKind) String() string {
	switch k {
	case JSONTokenKindString:
		return "string"
	case JSONTokenKindNumber:
		return "number"
	case JSONTokenKindTrue:
		return "true"
	case JSONTokenKindFalse:
		return "false"
	case JSONTokenKindSpaces:
		return "spaces"
	case JSONTokenKindComma:
		return "comma"
	case JSONTokenKindColon:
		return "colon"
	case JSONTokenKindOpenArray:
		return "open-array"
	case JSONTokenKindCloseArray:
		return "close-array"
	case JSONTokenKindOpenObject:
		return "open-object"
	case JSONTokenKindCloseObject:
		return "close-object"
	case JSONTokenKindNull:
		return "null"
	default:
		return "unknown"
	}
}

type JSONToken struct {
	Kind JSONTokenKind
	Raw  string
}
