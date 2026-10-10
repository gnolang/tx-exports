package arena

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
)

const (
	pageSize     = 8
	hotWindow    = 30
	followWindow = 40
)

// Render is the gnoweb client: feed, profiles, posts, and ticket markets.
func Render(path string) string {
	parts := splitPath(path)
	var b strings.Builder
	switch {
	case len(parts) == 0:
		renderFeed(&b, 0, true)
	case len(parts) == 1 && parts[0] == "feed":
		renderFeed(&b, 0, false)
	case len(parts) == 2 && parts[0] == "feed":
		id, ok := parsePositive(parts[1])
		if !ok {
			return notFound()
		}
		renderFeed(&b, id, false)
	case len(parts) == 1 && parts[0] == "people":
		renderPeople(&b, "")
	case len(parts) == 2 && parts[0] == "people":
		renderPeople(&b, parts[1])
	case len(parts) == 1 && parts[0] == "hot":
		renderHot(&b)
	case len(parts) == 1 && parts[0] == "about":
		renderAbout(&b)
	case len(parts) == 2 && parts[0] == "u":
		renderUser(&b, parts[1], 0)
	case len(parts) == 3 && parts[0] == "u":
		before, ok := parsePositive(parts[2])
		if !ok {
			return notFound()
		}
		renderUser(&b, parts[1], before)
	case len(parts) == 2 && parts[0] == "p":
		id, ok := parsePositive(parts[1])
		if !ok {
			return notFound()
		}
		renderPost(&b, id, 0)
	case len(parts) == 3 && parts[0] == "p":
		id, ok := parsePositive(parts[1])
		after, ok2 := parsePositive(parts[2])
		if !ok || !ok2 {
			return notFound()
		}
		renderPost(&b, id, after)
	case len(parts) == 2 && parts[0] == "t":
		renderTicket(&b, parts[1])
	case len(parts) == 2 && parts[0] == "following":
		renderFollowing(&b, parts[1])
	default:
		return notFound()
	}
	b.WriteString(footer())
	return b.String()
}

func renderFeed(b *strings.Builder, before int, composer bool) {
	b.WriteString("# Arena\n\n")
	b.WriteString(nav())
	b.WriteString("Bài viết, theo dõi, tip GNOT, và vé creator. Giá vé tăng theo bậc hai.\n\n")
	if state.paused {
		b.WriteString(note("WARNING", "Đang tạm dừng đăng, tip và mua vé. Bán vé vẫn mở."))
	}
	posts := recentPosts(before, pageSize)
	if len(posts) == 0 {
		b.WriteString(note("NOTE", "Chưa có bài. Hãy đăng ký và viết bài đầu tiên."))
	}
	for _, p := range posts {
		b.WriteString(postView(p, false))
	}
	if len(posts) == pageSize {
		last := posts[len(posts)-1].ID
		b.WriteString("[Bài cũ hơn](" + href("feed/"+strconv.Itoa(last)) + ")\n\n")
	}
	if composer {
		b.WriteString("## Đăng bài\n\n")
		b.WriteString(postForm())
		b.WriteString("## Đăng ký\n\n")
		b.WriteString(registerForm())
	}
}

func renderPeople(b *strings.Builder, after string) {
	b.WriteString("# Mọi người\n\n")
	b.WriteString(nav())
	rows := Handles(after, pageSize)
	if len(rows) == 0 {
		b.WriteString(note("NOTE", "Chưa có ai đăng ký."))
	}
	for _, p := range rows {
		b.WriteString("- [@" + p.Handle + "](" + href("u/"+p.Handle) + ") — " + sanitize.InlineText(p.Name) + "\n")
	}
	if len(rows) == pageSize {
		last := rows[len(rows)-1].Handle
		b.WriteString("\n[Trang sau](" + href("people/"+last) + ")\n")
	}
	b.WriteString("\n")
}

func renderHot(b *strings.Builder) {
	b.WriteString("# Đang nóng\n\n")
	b.WriteString(nav())
	b.WriteString("Chấm trong " + strconv.Itoa(hotWindow) + " bài mới: mỗi lượt thích cộng 1 GNOT, cộng thêm tip.\n\n")
	top := Hot(pageSize)
	if len(top) == 0 {
		b.WriteString(note("NOTE", "Chưa có bài để xếp."))
		return
	}
	for i := range top {
		b.WriteString(postView(&top[i], false))
	}
}

type scoredPost struct {
	p     *Article
	score int64
}

func insertRank(top []scoredPost, row scoredPost, limit int) []scoredPost {
	if len(top) == limit && row.score <= top[len(top)-1].score {
		return top
	}
	top = append(top, row)
	for i := len(top) - 1; i > 0; i-- {
		if top[i].score <= top[i-1].score {
			break
		}
		top[i], top[i-1] = top[i-1], top[i]
	}
	if len(top) > limit {
		top = top[:limit]
	}
	return top
}

func renderAbout(b *strings.Builder) {
	b.WriteString("# Cách chơi\n\n")
	b.WriteString(nav())
	b.WriteString("Arena trên Gnoland lấy mô hình của arena.social: mạng xã hội cộng vé creator.\n\n")
	b.WriteString("## Vé\n\n")
	b.WriteString("Vé thứ `i` (bắt đầu từ 1) có giá `i × i × 0.01 GNOT`. Mua và bán dùng tổng đúng của các bậc đó.\n\n")
	b.WriteString("Phí tính trên phần curve, trả thêm khi mua và trừ khi bán:\n\n")
	b.WriteString("- " + pct(CreatorFeeBps) + " về creator\n")
	b.WriteString("- " + pct(ProtocolFeeBps) + " về quỹ protocol\n")
	b.WriteString("- " + pct(ReferralFeeBps) + " về người đã mời creator, nếu có\n\n")
	b.WriteString("Khoản curve nằm lại làm dự trữ. Phí được chuyển đi ngay, không trộn vào dự trữ, nên bán lại luôn đủ tiền. Mỗi lệnh tối đa " + strconv.Itoa(MaxTrade) + " vé, mỗi creator tối đa " + strconv.Itoa(MaxSupply) + " vé.\n\n")
	b.WriteString(note("NOTE", "Admin không rút dự trữ. Sweep chỉ gửi số GNOT nằm trên khoản dự trữ."))
	b.WriteString("## Bài khóa vé\n\n")
	b.WriteString(note("WARNING", "Chain công khai. Trang không in nội dung bài khóa, và GatedBody chỉ trả lời cho tác giả hoặc người đang giữ vé, nhưng ai đọc storage vẫn thấy. Xóa bài chỉ xóa state hiện tại; giao dịch cũ vẫn còn trong lịch sử."))
	b.WriteString("## Tip\n\n")
	b.WriteString("Tip đính kèm ugnot khi gọi `Tip`. Toàn bộ về tác giả của bài.\n\n")
	b.WriteString("## Quản trị\n\n")
	b.WriteString("Phiên bản `" + Version() + "`. Admin `" + Admin().String() + "` · quỹ `" + Treasury().String() + "`\n\n")
	if Successor() != "" {
		b.WriteString("Phiên bản kế: `" + Successor() + "`\n\n")
	}
	b.WriteString("<gno-form exec=\"SetSuccessor\">\n<gno-input name=\"next\" placeholder=\"gno.land/r/… để trống thì xóa\" description=\"Chỉ ghi đường dẫn gói sau. Không chuyển dự trữ vé.\" />\n</gno-form>\n")
	b.WriteString("<gno-form exec=\"SetPaused\">\n<gno-input name=\"on\" placeholder=\"true hoặc false\" description=\"Tạm dừng đăng, tip và mua vé. Bán vé vẫn chạy.\" />\n</gno-form>\n")
	b.WriteString("<gno-form exec=\"SetTreasury\">\n<gno-input name=\"next\" placeholder=\"địa chỉ quỹ mới\" />\n</gno-form>\n")
	b.WriteString("<gno-form exec=\"TransferAdmin\">\n<gno-input name=\"next\" placeholder=\"địa chỉ admin mới\" />\n</gno-form>\n")
	b.WriteString("<gno-form exec=\"Sweep\">\n<gno-input name=\"confirm\" placeholder=\"gõ sweep\" description=\"Chỉ quét số dư thừa, không đụng dự trữ vé.\" />\n</gno-form>\n")
}

func renderUser(b *strings.Builder, handle string, before int) {
	p := lookup(handle)
	if p == nil {
		b.WriteString("# Arena\n\n")
		b.WriteString(nav())
		b.WriteString(note("WARNING", "Không có handle này."))
		return
	}
	b.WriteString("# @" + p.Handle + "\n\n")
	b.WriteString(nav())
	b.WriteString("**" + sanitize.InlineText(p.Name) + "**\n\n")
	if p.Bio != "" {
		b.WriteString(sanitize.Block(p.Bio))
		b.WriteString("\n")
	}
	b.WriteString("`" + p.Addr.String() + "`\n\n")
	b.WriteString(strconv.Itoa(p.Posts) + " bài · " + strconv.Itoa(p.Following) + " đang theo dõi · " + strconv.Itoa(p.Followers) + " người theo dõi · tip nhận " + gnot(p.TipsIn) + "\n\n")
	supply, reserve, holders := SupplyOf(p.Handle)
	next := "hết cung"
	if supply < MaxSupply {
		due, _, _, _, _ := QuoteBuy(p.Handle, 1)
		next = gnot(due)
	}
	b.WriteString("[Vé](" + href("t/"+p.Handle) + "): cung " + strconv.Itoa(supply) + " · " + strconv.Itoa(holders) + " người giữ · dự trữ " + gnot(reserve) + " · vé kế " + next + "\n\n")
	if p.Referrer.IsValid() {
		if ref := profileByAddr(p.Referrer); ref != nil {
			b.WriteString("Được mời bởi [@" + ref.Handle + "](" + href("u/"+ref.Handle) + ")\n\n")
		}
	}
	b.WriteString("## Bài\n\n")
	posts := PostsBy(p.Addr, before, pageSize)
	if len(posts) == 0 {
		b.WriteString(note("NOTE", "Chưa có bài."))
	}
	for i := range posts {
		b.WriteString(postView(&posts[i], false))
	}
	if len(posts) == pageSize {
		last := posts[len(posts)-1].ID
		b.WriteString("[Bài cũ hơn](" + href("u/"+p.Handle+"/"+strconv.Itoa(last)) + ")\n\n")
	}
	b.WriteString("## Theo dõi\n\n")
	b.WriteString("<gno-form exec=\"Follow\">\n<gno-input name=\"handle\" value=\"" + p.Handle + "\" readonly=\"true\" />\n</gno-form>\n")
	b.WriteString("<gno-form exec=\"Unfollow\">\n<gno-input name=\"handle\" value=\"" + p.Handle + "\" readonly=\"true\" />\n</gno-form>\n")
	b.WriteString("## Sửa hồ sơ\n\n")
	b.WriteString("<gno-form exec=\"UpdateProfile\">\n<gno-input name=\"name\" placeholder=\"tên hiển thị\" />\n<gno-input name=\"bio\" placeholder=\"giới thiệu\" />\n</gno-form>\n")
}

func renderPost(b *strings.Builder, id, after int) {
	p := postByID(id)
	b.WriteString("# Bài #" + strconv.Itoa(id) + "\n\n")
	b.WriteString(nav())
	if p == nil {
		b.WriteString(note("WARNING", "Không có bài này."))
		return
	}
	if p.ReplyTo != 0 {
		b.WriteString("Trả lời [#" + strconv.Itoa(p.ReplyTo) + "](" + href("p/"+strconv.Itoa(p.ReplyTo)) + ")\n\n")
	}
	b.WriteString(postView(p, true))
	if p.Deleted {
		return
	}
	b.WriteString(likeForm(id))
	b.WriteString(unlikeForm(id))
	b.WriteString("## Tip\n\n")
	b.WriteString(tipForm(id))
	b.WriteString("## Trả lời\n\n")
	b.WriteString(replyForm(id))
	kids := Replies(id, after, pageSize)
	for i := range kids {
		b.WriteString(postView(&kids[i], false))
	}
	if len(kids) == pageSize {
		last := kids[len(kids)-1].ID
		b.WriteString("[Trả lời tiếp](" + href("p/"+strconv.Itoa(id)+"/"+strconv.Itoa(last)) + ")\n\n")
	}
	b.WriteString("<gno-form exec=\"Delete\">\n<gno-input name=\"id\" type=\"number\" value=\"" + strconv.Itoa(id) + "\" readonly=\"true\" description=\"Chỉ tác giả xóa được.\" />\n</gno-form>\n")
}

func renderTicket(b *strings.Builder, handle string) {
	p := lookup(handle)
	b.WriteString("# Vé\n\n")
	b.WriteString(nav())
	if p == nil {
		b.WriteString(note("WARNING", "Không có handle này."))
		return
	}
	b.WriteString("Creator [@" + p.Handle + "](" + href("u/"+p.Handle) + ")\n\n")
	supply, reserve, holders := SupplyOf(p.Handle)
	b.WriteString("Cung " + strconv.Itoa(supply) + " · người giữ " + strconv.Itoa(holders) + " · dự trữ " + gnot(reserve) + " (" + ugnot(reserve) + ")\n\n")
	b.WriteString("| Vé | Curve | Phải gửi khi mua | Nhận khi bán |\n")
	b.WriteString("| --- | --- | --- | --- |\n")
	for _, n := range []int{1, 2, 5} {
		if supply+n > MaxSupply {
			continue
		}
		due, curve, _, _, _ := QuoteBuy(p.Handle, n)
		sell := "—"
		if n <= supply {
			proceeds, _, _, _, _ := QuoteSell(p.Handle, n)
			sell = ugnot(proceeds)
		}
		b.WriteString("| " + strconv.Itoa(n) + " | " + ugnot(curve) + " | " + ugnot(due) + " | " + sell + " |\n")
	}
	b.WriteString("\nĐính kèm đúng số ugnot khi mua. Nếu cung đổi trước giao dịch, realm báo số mới và hoàn tiền.\n\n")
	b.WriteString("<gno-form exec=\"Buy\">\n<gno-input name=\"handle\" value=\"" + p.Handle + "\" readonly=\"true\" />\n<gno-input name=\"amount\" type=\"number\" placeholder=\"số vé muốn mua\" />\n</gno-form>\n")
	b.WriteString("<gno-form exec=\"Sell\">\n<gno-input name=\"handle\" value=\"" + p.Handle + "\" readonly=\"true\" />\n<gno-input name=\"amount\" type=\"number\" placeholder=\"số vé muốn bán\" />\n</gno-form>\n")
}

func renderFollowing(b *strings.Builder, raw string) {
	b.WriteString("# Đang theo dõi\n\n")
	b.WriteString(nav())
	if len(raw) > 60 {
		b.WriteString(note("WARNING", "Địa chỉ không hợp lệ."))
		return
	}
	who := address(raw)
	if !who.IsValid() {
		b.WriteString(note("WARNING", "Địa chỉ không hợp lệ."))
		return
	}
	b.WriteString("Bài của những người `" + who.String() + "` đang theo dõi, trong " + strconv.Itoa(followWindow) + " bài mới.\n\n")
	posts := recentPosts(0, followWindow)
	shown := 0
	for _, p := range posts {
		if !state.follows.Has(followKey(who, p.Author)) {
			continue
		}
		b.WriteString(postView(p, false))
		shown++
		if shown >= pageSize {
			break
		}
	}
	if shown == 0 {
		b.WriteString(note("NOTE", "Chưa có bài mới từ những người này."))
	}
}

func postView(p *Article, full bool) string {
	h := handleOf(p.Author)
	var b strings.Builder
	b.WriteString("### [@" + h + "](" + href("u/"+h) + ") · [#" + strconv.Itoa(p.ID) + "](" + href("p/"+strconv.Itoa(p.ID)) + ")\n\n")
	if p.Deleted {
		b.WriteString(note("WARNING", "Bài đã xóa."))
		return b.String()
	}
	switch {
	case p.Gated && full:
		b.WriteString(note("NOTE", "Bài khóa vé. Trang không hiện nội dung. GatedBody trả nội dung cho tác giả hoặc người đang giữ vé."))
		b.WriteString(gatedForm(p.ID))
	case p.Gated:
		b.WriteString(note("NOTE", "Bài khóa vé."))
	case full:
		b.WriteString(sanitize.Block(p.Body))
		b.WriteString("\n")
	default:
		b.WriteString(sanitize.InlineText(preview(strings.ReplaceAll(p.Body, "\n", " "), 160)))
		b.WriteString("\n\n")
	}
	b.WriteString(strconv.Itoa(p.Likes) + " thích · " + strconv.Itoa(p.Replies) + " trả lời · tip " + gnot(p.Tips) + "\n\n")
	return b.String()
}

func recentPosts(before, limit int) []*Article {
	end := ""
	if before > 0 {
		end = pad(before)
	}
	out := make([]*Article, 0, limit)
	state.feed.ReverseIterate("", end, func(key string, value any) bool {
		id, ok := value.(int)
		if !ok {
			panic("feed type")
		}
		if before > 0 && id >= before {
			return false
		}
		p := postByID(id)
		if p == nil || p.Deleted || p.ReplyTo != 0 {
			return false
		}
		out = append(out, p)
		return len(out) >= limit
	})
	return out
}

func authorPosts(a address, limit int) []*Article {
	prefix := a.String() + "/"
	out := make([]*Article, 0, limit)
	state.byAuthor.ReverseIterate(prefix, prefix+"~", func(key string, value any) bool {
		id, ok := value.(int)
		if !ok {
			panic("author type")
		}
		p := postByID(id)
		if p == nil || p.Deleted {
			return false
		}
		out = append(out, p)
		return len(out) >= limit
	})
	return out
}

func childReplies(parent, limit int) []*Article {
	prefix := pad(parent) + "/"
	out := make([]*Article, 0, limit)
	state.replies.Iterate(prefix, prefix+"~", func(key string, value any) bool {
		id, ok := value.(int)
		if !ok {
			panic("reply type")
		}
		p := postByID(id)
		if p == nil || p.Deleted {
			return false
		}
		out = append(out, p)
		return len(out) >= limit
	})
	return out
}

func handleOf(a address) string {
	if p := profileByAddr(a); p != nil {
		return p.Handle
	}
	return a.String()
}

func postForm() string {
	return "<gno-form exec=\"Post\">\n" +
		"<gno-textarea name=\"body\" rows=\"4\" placeholder=\"Bạn đang nghĩ gì?\" description=\"Tối đa 280 ký tự.\" />\n" +
		"<gno-input name=\"gated\" placeholder=\"khóa vé: để trống hoặc yes\" description=\"yes chỉ giấu nội dung trên trang. State trên chain vẫn công khai.\" />\n" +
		"</gno-form>\n"
}

func registerForm() string {
	return "<gno-form exec=\"Register\">\n" +
		"<gno-input name=\"handle\" placeholder=\"handle\" description=\"3–16 ký tự: a-z, 0-9, gạch dưới.\" />\n" +
		"<gno-input name=\"name\" placeholder=\"tên hiển thị\" />\n" +
		"<gno-input name=\"bio\" placeholder=\"giới thiệu\" />\n" +
		"<gno-input name=\"referrer\" placeholder=\"địa chỉ người mời, có thể trống\" />\n" +
		"</gno-form>\n"
}

func likeForm(id int) string {
	return "<gno-form exec=\"Like\">\n<gno-input name=\"id\" type=\"number\" value=\"" + strconv.Itoa(id) + "\" readonly=\"true\" />\n</gno-form>\n"
}

func unlikeForm(id int) string {
	return "<gno-form exec=\"Unlike\">\n<gno-input name=\"id\" type=\"number\" value=\"" + strconv.Itoa(id) + "\" readonly=\"true\" />\n</gno-form>\n"
}

func tipForm(id int) string {
	return "<gno-form exec=\"Tip\">\n<gno-input name=\"id\" type=\"number\" value=\"" + strconv.Itoa(id) + "\" readonly=\"true\" description=\"Đính kèm ugnot trong ví. 100% về tác giả.\" />\n</gno-form>\n"
}

func replyForm(id int) string {
	return "<gno-form exec=\"Reply\">\n" +
		"<gno-input name=\"parent\" type=\"number\" value=\"" + strconv.Itoa(id) + "\" readonly=\"true\" />\n" +
		"<gno-textarea name=\"body\" rows=\"3\" placeholder=\"Trả lời\" />\n" +
		"</gno-form>\n"
}

func gatedForm(id int) string {
	return "<gno-form exec=\"GatedBody\">\n<gno-input name=\"id\" type=\"number\" value=\"" + strconv.Itoa(id) + "\" readonly=\"true\" description=\"Kết quả trả về trong giao dịch, không in ra trang.\" />\n</gno-form>\n"
}

func nav() string {
	return "[Bảng tin](" + href("") + ") · [Mọi người](" + href("people") + ") · [Nóng](" + href("hot") + ") · [Cách chơi](" + href("about") + ")\n\n"
}

func footer() string {
	s := "Phiên bản " + Version() + ". Phí vé " + pct(CreatorFeeBps) + " creator · " + pct(ProtocolFeeBps) + " protocol · " + pct(ReferralFeeBps) + " người mời"
	if state.paused {
		s += " · đang tạm dừng mua và đăng"
	}
	if next := Successor(); next != "" {
		s += "\n\nPhiên bản kế: [" + next + "](/" + strings.TrimPrefix(next, "gno.land/") + ")"
	}
	return "\n---\n" + s + "\n"
}

func href(sub string) string {
	base := webBase()
	if sub == "" {
		return base
	}
	return base + ":" + sub
}

func webBase() string {
	p := unsafe.CurrentRealm().PkgPath()
	if strings.HasPrefix(p, "gno.land/") {
		return "/" + strings.TrimPrefix(p, "gno.land/")
	}
	return "/r/gnosocial/arena"
}

func notFound() string {
	return "# Arena\n\n" + note("WARNING", "Không có trang này.") + nav()
}

func note(kind, text string) string {
	return "> [!" + kind + "]\n> " + text + "\n\n"
}

func pct(bps int64) string {
	whole := bps / 100
	frac := bps % 100
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + "%"
	}
	return strconv.FormatInt(whole, 10) + "." + strconv.FormatInt(frac, 10) + "%"
}

func gnot(n int64) string {
	sign := ""
	if n < 0 {
		sign = "-"
		n = -n
	}
	whole := n / 1_000_000
	frac := n % 1_000_000
	return sign + strconv.FormatInt(whole, 10) + "." + leftPad(frac, 6) + " GNOT"
}

func ugnot(n int64) string {
	return strconv.FormatInt(n, 10) + " ugnot"
}

func leftPad(n int64, width int) string {
	s := strconv.FormatInt(n, 10)
	for len(s) < width {
		s = "0" + s
	}
	return s
}

func splitPath(path string) []string {
	path = strings.Trim(path, "/")
	if path == "" {
		return nil
	}
	return strings.Split(path, "/")
}

func parsePositive(s string) (int, bool) {
	if s == "" || len(s) > 10 {
		return 0, false
	}
	n, err := strconv.Atoi(s)
	if err != nil || n <= 0 {
		return 0, false
	}
	return n, true
}

func preview(s string, n int) string {
	if len(s) <= n {
		return s
	}
	i := n
	for i > 0 && s[i]&0xC0 == 0x80 {
		i--
	}
	return s[:i] + "…"
}
