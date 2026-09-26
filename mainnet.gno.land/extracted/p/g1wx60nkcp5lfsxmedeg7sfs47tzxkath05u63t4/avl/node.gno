package avl

type Node struct {
	key       string // key is the unique identifier for the node.
	value     any    // value is the data stored in the node.
	height    int8   // height is the height of the node in the tree.
	size      int    // size is the number of leaf nodes (key-value pairs) in the subtree rooted at this node.
	leftNode  *Node  // leftNode is the left child of the node.
	rightNode *Node  // rightNode is the right child of the node.
}

func NewNode(key string, value any) *Node {
	return &Node{
		key:    key,
		value:  value,
		height: 0,
		size:   1,
	}
}

func (node *Node) Size() int {
	if node == nil {
		return 0
	}
	return node.size
}

func (node *Node) IsLeaf() bool {
	return node.height == 0
}

func (node *Node) Key() string {
	return node.key
}

func (node *Node) Value() any {
	return node.value
}

func (node *Node) _copy() *Node {
	if node.height == 0 {
		panic("Why are you copying a value node?")
	}
	return &Node{
		key:       node.key,
		height:    node.height,
		size:      node.size,
		leftNode:  node.leftNode,
		rightNode: node.rightNode,
	}
}

func (node *Node) Has(key string) (has bool) {
	if node == nil {
		return false
	}
	if node.key == key {
		return true
	}
	if node.height == 0 {
		return false
	} else {
		if key < node.key {
			return node.getLeftNode().Has(key)
		} else {
			return node.getRightNode().Has(key)
		}
	}
}

func (node *Node) Get(key string) (index int, value any, exists bool) {
	if node == nil {
		return 0, nil, false
	}

	if node.height == 0 {
		if node.key == key {
			return 0, node.value, true
		} else if node.key < key {
			return 1, nil, false
		} else {
			return 0, nil, false
		}
	} else {
		if key < node.key {
			return node.getLeftNode().Get(key)
		} else {
			rightNode := node.getRightNode()
			index, value, exists = rightNode.Get(key)
			index += node.size - rightNode.size
			return index, value, exists
		}
	}
}

func (node *Node) GetByIndex(index int) (key string, value any) {
	if index < 0 {
		panic("GetByIndex: negative index not allowed")
	}

	if node.height == 0 {
		if index != 0 {
			panic("GetByIndex asked for invalid index")
		}
		return node.key, node.value
	} else {
		leftNode := node.getLeftNode()
		if index < leftNode.size {
			return leftNode.GetByIndex(index)
		} else {
			return node.getRightNode().GetByIndex(index - leftNode.size)
		}
	}
}

func (node *Node) Set(key string, value any) (newSelf *Node, updated bool) {
	if node == nil {
		return NewNode(key, value), false
	}
	if node.height == 0 {
		if key < node.key {
			return &Node{
				key:       node.key,
				height:    1,
				size:      2,
				leftNode:  NewNode(key, value),
				rightNode: node,
			}, false
		} else if key == node.key {
			return NewNode(key, value), true
		} else {
			return &Node{
				key:       key,
				height:    1,
				size:      2,
				leftNode:  node,
				rightNode: NewNode(key, value),
			}, false
		}
	} else {
		node = node._copy()
		if key < node.key {
			node.leftNode, updated = node.getLeftNode().Set(key, value)
		} else {
			node.rightNode, updated = node.getRightNode().Set(key, value)
		}
		if updated {
			return node, updated
		} else {
			node.calcHeightAndSize()
			return node.balance(), updated
		}
	}
}

func (node *Node) Remove(key string) (
	newNode *Node, newKey string, value any, removed bool,
) {
	if node == nil {
		return nil, "", nil, false
	}
	if node.height == 0 {
		if key == node.key {
			return nil, "", node.value, true
		} else {
			return node, "", nil, false
		}
	} else {
		if key < node.key {
			var newLeftNode *Node
			newLeftNode, newKey, value, removed = node.getLeftNode().Remove(key)
			if !removed {
				return node, "", value, false
			} else if newLeftNode == nil { // left node held value, was removed
				return node.rightNode, node.key, value, true
			}
			node = node._copy()
			node.leftNode = newLeftNode
			node.calcHeightAndSize()
			node = node.balance()
			return node, newKey, value, true
		} else {
			var newRightNode *Node
			newRightNode, newKey, value, removed = node.getRightNode().Remove(key)
			if !removed {
				return node, "", value, false
			} else if newRightNode == nil { // right node held value, was removed
				return node.leftNode, "", value, true
			}
			node = node._copy()
			node.rightNode = newRightNode
			if newKey != "" {
				node.key = newKey
			}
			node.calcHeightAndSize()
			node = node.balance()
			return node, "", value, true
		}
	}
}

func (node *Node) getLeftNode() *Node {
	return node.leftNode
}

func (node *Node) getRightNode() *Node {
	return node.rightNode
}

func (node *Node) rotateRight() *Node {
	node = node._copy()
	l := node.getLeftNode()
	_l := l._copy()

	_lrCached := _l.rightNode
	_l.rightNode = node
	node.leftNode = _lrCached

	node.calcHeightAndSize()
	_l.calcHeightAndSize()

	return _l
}

func (node *Node) rotateLeft() *Node {
	node = node._copy()
	r := node.getRightNode()
	_r := r._copy()

	_rlCached := _r.leftNode
	_r.leftNode = node
	node.rightNode = _rlCached

	node.calcHeightAndSize()
	_r.calcHeightAndSize()

	return _r
}

func (node *Node) calcHeightAndSize() {
	node.height = maxInt8(node.getLeftNode().height, node.getRightNode().height) + 1
	node.size = node.getLeftNode().size + node.getRightNode().size
}

func (node *Node) calcBalance() int {
	return int(node.getLeftNode().height) - int(node.getRightNode().height)
}

func (node *Node) balance() (newSelf *Node) {
	balance := node.calcBalance()
	if balance > 1 {
		if node.getLeftNode().calcBalance() >= 0 {
			return node.rotateRight()
		} else {
			left := node.getLeftNode()
			node.leftNode = left.rotateLeft()
			return node.rotateRight()
		}
	}
	if balance < -1 {
		if node.getRightNode().calcBalance() <= 0 {
			return node.rotateLeft()
		} else {
			right := node.getRightNode()
			node.rightNode = right.rotateRight()
			return node.rotateLeft()
		}
	}
	return node
}

func (node *Node) Iterate(start, end string, cb func(*Node) bool) bool {
	return node.TraverseInRange(start, end, true, true, cb)
}

func (node *Node) ReverseIterate(start, end string, cb func(*Node) bool) bool {
	return node.TraverseInRange(start, end, false, true, cb)
}

func (node *Node) TraverseInRange(start, end string, ascending bool, leavesOnly bool, cb func(*Node) bool) bool {
	if node == nil {
		return false
	}
	afterStart := (start == "" || start < node.key)
	startOrAfter := (start == "" || start <= node.key)
	beforeEnd := false
	if ascending {
		beforeEnd = (end == "" || node.key < end)
	} else {
		beforeEnd = (end == "" || node.key <= end)
	}

	stop := false
	if (!node.IsLeaf() && !leavesOnly) ||
		(node.IsLeaf() && startOrAfter && beforeEnd) {
		stop = cb(node)
		if stop {
			return stop
		}
	}
	if node.IsLeaf() {
		return stop
	}

	if ascending {
		if afterStart {
			stop = node.getLeftNode().TraverseInRange(start, end, ascending, leavesOnly, cb)
		}
		if stop {
			return stop
		}
		if beforeEnd {
			stop = node.getRightNode().TraverseInRange(start, end, ascending, leavesOnly, cb)
		}
	} else {
		if beforeEnd {
			stop = node.getRightNode().TraverseInRange(start, end, ascending, leavesOnly, cb)
		}
		if stop {
			return stop
		}
		if afterStart {
			stop = node.getLeftNode().TraverseInRange(start, end, ascending, leavesOnly, cb)
		}
	}

	return stop
}

func (node *Node) TraverseByOffset(offset, limit int, ascending bool, leavesOnly bool, cb func(*Node) bool) bool {
	if node == nil {
		return false
	}

	if offset < 0 {
		offset = 0
	}

	if limit <= 0 || offset >= node.size {
		return false
	}
	if node.IsLeaf() {
		if offset > 0 {
			return false
		}
		return cb(node)
	}

	return node.traverseByOffset(offset, limit, ascending, leavesOnly, cb)
}

func (node *Node) traverseByOffset(offset, limit int, ascending bool, leavesOnly bool, cb func(*Node) bool) bool {
	if !leavesOnly {
		if cb(node) {
			return true // Stop traversal if callback returns true
		}
	}
	first, second := node.getLeftNode(), node.getRightNode()
	if !ascending {
		first, second = second, first
	}
	if first.IsLeaf() {
		if offset > 0 {
			offset--
		} else {
			if cb(first) {
				return true // Stop traversal if callback returns true
			}
			limit--
			if limit <= 0 {
				return true // Stop traversal when limit is reached
			}
		}
	} else {
		if offset >= first.size {
			offset -= first.size // 1
		} else {
			if first.traverseByOffset(offset, limit, ascending, leavesOnly, cb) {
				return true
			}
			delta := first.size - offset
			offset = 0
			if delta >= limit {
				return true // 3
			}
			limit -= delta // 2
		}
	}

	if second.IsLeaf() {
		return cb(second)
	}
	return second.traverseByOffset(offset, limit, ascending, leavesOnly, cb)
}

func (node *Node) lmd() *Node {
	if node.height == 0 {
		return node
	}
	return node.getLeftNode().lmd()
}

func (node *Node) rmd() *Node {
	if node.height == 0 {
		return node
	}
	return node.getRightNode().rmd()
}

func maxInt8(a, b int8) int8 {
	if a > b {
		return a
	}
	return b
}
