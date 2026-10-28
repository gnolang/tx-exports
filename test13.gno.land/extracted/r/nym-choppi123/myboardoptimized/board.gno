package myboardoptimized

import "strconv"

var (
    boardName string = "Mon Forum Optimisé"
    posts     []string
)

func init() {
    posts = make([]string, 0, 100)
}

func GetBoardName() string {
    return boardName
}

// OPTIMISÉ : Slice au lieu de map + pré-allocation
func CreatePost(content string) int {
    posts = append(posts, content)
    return len(posts)
}

func GetPost(id int) string {
    if id > 0 && id <= len(posts) {
        return posts[id-1]
    }
    return ""
}

func GetPostCount() int {
    return len(posts)
}

// OPTIMISÉ : Limite à 5 posts dans Render
func Render(path string) string {
    output := "# " + boardName + "\n\n"
    output += "## Publications (" + strconv.Itoa(len(posts)) + ")\n\n"
    
    limit := 5
    if len(posts) < 5 {
        limit = len(posts)
    }
    
    for i := 0; i < limit; i++ {
        output += strconv.Itoa(i+1) + ". " + posts[i] + "\n\n"
    }
    
    if len(posts) > 5 {
        output += "... et " + strconv.Itoa(len(posts)-5) + " posts de plus\n\n"
    }
    
    return output
}
