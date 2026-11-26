package cellar

import "gno.land/p/g1pqtgghwrs33pxfl492yruc6l6x83hpr5lf46kr/cellar/formula/v1"

// template is a sheet that is ready to use.
type template struct {
	name, help string
	cols, rows int
	blocks     [][2]string // where to paste what
	fills      [][2]string // cells to copy into areas
	open       string      // area for visitors, or ""
	chart      *chart
}

func templates() []template {
	return []template{
		{
			name: "contest",
			help: "three judges score up to five entries; shares go to the best three. Entrust B2:B6, C2:C6 and D2:D6 to the judges, put the payees in column G, then lock E2:G6 and E8.",
			cols: 7, rows: 10,
			blocks: [][2]string{
				{"A1", "Entry|Judge 1|Judge 2|Judge 3|Total|Share|Payee"},
				{"E2", "=SUM(B2:D2)|=IF(COUNTA(A2)=0,0,CHOOSE(RANK(E2,E$2:E$6),50,30,20,0,0))"},
				{"A8", "All scores in?||||=AND(COUNTA(A2:A6)>0,COUNT(B2:D6)=3*COUNTA(A2:A6))"},
				{"A9", "Leader||||=IF(MAX(E2:E6)=0,\"nobody yet\",XLOOKUP(MAX(E2:E6),E2:E6,A2:A6))"},
			},
			fills: [][2]string{{"E2", "E3:E6"}, {"F2", "F3:F6"}},
			chart: &chart{kind: "bar", title: "Scores", labels: area("A2:A6"), values: area("E2:E6")},
		},
		{
			name: "signup",
			help: "a list that anyone can add to. Who added a row is shown next to it.",
			cols: 4, rows: 22,
			blocks: [][2]string{
				{"A1", "Name|What|How many|Added by"},
				{"D2", "=EDITOR(A2)"},
				{"A22", "Total||=SUM(C2:C20)"},
			},
			fills: [][2]string{{"D2", "D3:D20"}},
			open:  "A2:C20",
		},
		{
			name: "split",
			help: "shared expenses: who paid what, and who is owed or owes how much.",
			cols: 4, rows: 12,
			blocks: [][2]string{
				{"A1", "Who|Paid|Fair share|Gets back"},
				{"C2", "=IF(A2=\"\",0,ROUND(SUM(B$2:B$9)/COUNTA(A$2:A$9),2))|=B2-C2"},
				{"A11", "Total|=SUM(B2:B9)|=SUM(C2:C9)"},
			},
			fills: [][2]string{{"C2", "C3:C9"}, {"D2", "D3:D9"}},
			chart: &chart{kind: "bar", title: "Paid", labels: area("A2:A9"), values: area("B2:B9")},
		},
		{
			name: "vault",
			help: "live GNOT balances: put addresses in column B.",
			cols: 4, rows: 12,
			blocks: [][2]string{
				{"A1", "Account|Address|GNOT|Share"},
				{"C2", "=IF(B2=\"\",0,BALANCE(B2))|=IF(C$10=0,\"\",BAR(C2,C$10,12))"},
				{"A10", "Total||=SUM(C2:C8)"},
			},
			fills: [][2]string{{"C2", "C3:C8"}, {"D2", "D3:D8"}},
		},
	}
}

// NewFromTemplate opens a sheet made from a template. It belongs to the caller,
// who can change everything about it.
func NewFromTemplate(cur realm, template, name, title string) {
	owner := cur.Previous().Address()
	for _, t := range templates() {
		if t.name != template {
			continue
		}
		s := open(owner, name, title, t.cols, t.rows)
		for _, b := range t.blocks {
			col, row := s.mustCell(b[0])
			s.paste(owner, col, row, b[1])
		}
		for _, f := range t.fills {
			col, row := s.mustCell(f[0])
			s.fill(owner, col, row, s.mustArea(f[1]))
		}
		if t.open != "" {
			s.grants = append(s.grants, grant{s.mustArea(t.open), anyone, false})
		}
		if t.chart != nil {
			s.charts = append(s.charts, *t.chart)
		}
		return
	}
	panic("cellar: no such template")
}

func area(name string) formula.Range {
	a, _ := formula.ParseArea(name)
	return a
}
