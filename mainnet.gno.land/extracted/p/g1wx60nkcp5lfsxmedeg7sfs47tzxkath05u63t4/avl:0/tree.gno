package avl

type ITree interface {

	Size() int
	Has(key string) bool
	Get(key string) any
	GetByIndex(index int) (key string, value any)
	Iterate(start, end string, cb IterCbFn) bool
	ReverseIterate(start, end string, cb IterCbFn) bool
	IterateByOffset(offset int, count int, cb IterCbFn) bool
	ReverseIterateByOffset(offset int, count int, cb IterCbFn) bool

	Set(key string, value any) (updated bool)
	Remove(key string) (value any, removed bool)
}

type IterCbFn func(key string, value any) bool

type Tree struct {
	node *Node
}

func NewTree() *Tree {
	return &Tree{
		node: nil,
	}
}

func (tree *Tree) Size() int {
	return tree.node.Size()
}

func (tree *Tree) Has(key string) (has bool) {
	return tree.node.Has(key)
}

func (tree *Tree) Get(key string) any {
	_, value, _ := tree.node.Get(key)
	return value
}

func (tree *Tree) GetByIndex(index int) (key string, value any) {
	return tree.node.GetByIndex(index)
}

func (tree *Tree) Set(key string, value any) (updated bool) {
	newnode, updated := tree.node.Set(key, value)
	tree.node = newnode
	return updated
}

func (tree *Tree) Remove(key string) (value any, removed bool) {
	newnode, _, value, removed := tree.node.Remove(key)
	tree.node = newnode
	return value, removed
}

func (tree *Tree) Iterate(start, end string, cb IterCbFn) bool {
	return tree.node.TraverseInRange(start, end, true, true,
		func(node *Node) bool {
			return cb(node.Key(), node.Value())
		},
	)
}

func (tree *Tree) ReverseIterate(start, end string, cb IterCbFn) bool {
	return tree.node.TraverseInRange(start, end, false, true,
		func(node *Node) bool {
			return cb(node.Key(), node.Value())
		},
	)
}

func (tree *Tree) IterateByOffset(offset int, count int, cb IterCbFn) bool {
	return tree.node.TraverseByOffset(offset, count, true, true,
		func(node *Node) bool {
			return cb(node.Key(), node.Value())
		},
	)
}

func (tree *Tree) ReverseIterateByOffset(offset int, count int, cb IterCbFn) bool {
	return tree.node.TraverseByOffset(offset, count, false, true,
		func(node *Node) bool {
			return cb(node.Key(), node.Value())
		},
	)
}

var _ ITree = (*Tree)(nil)
