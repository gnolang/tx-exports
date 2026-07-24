package myboard

import "strconv"

var (
    boardName string = "Mon Forum"
    posts     map[int]string
    postCount int
)

func init() {
    posts = make(map[int]string)
    postCount = 0
}

func GetBoardName() string {
    return boardName
}

func CreatePost(content string) int {
    postCount++
    posts[postCount] = content
    return postCount
}

func GetPost(id int) string {
    return posts[id]
}

func GetPostCount() int {
    return postCount
}

func Render(path string) string {
    output := "# " + boardName + "\n\n"
    output += "## Publications (" + strconv.Itoa(postCount) + ")\n\n"
    
    for i := 1; i <= postCount; i++ {
        if post, exists := posts[i]; exists {
            output += strconv.Itoa(i) + ". " + post + "\n\n"
        }
    }
    
    if path != "" {
        output += "---\n**Vue détaillée:** " + path
    }
    
    return output
}
