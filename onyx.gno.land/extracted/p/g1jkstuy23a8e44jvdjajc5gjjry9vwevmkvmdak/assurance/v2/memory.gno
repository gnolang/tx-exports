package assurance

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"strings"

	"gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/signals/v2"
)

const (
	DomainMemoryRecord = "arobi-assurance-memory-record-v1"
	DomainMemoryRecall = "arobi-assurance-memory-recall-v1"

	MemoryKindEpisodic   = "episodic"
	MemoryKindSemantic   = "semantic"
	MemoryKindProcedural = "procedural"

	// DefaultRRFK is the standard Reciprocal Rank Fusion smoothing constant (k = 60).
	DefaultRRFK int64 = 60
)

// MemoryRecord is an immutable, provenance-bound memory entry stored in a deterministic
// fixed-point MemoryVault. Every record carries both a quantized unit embedding (for dense
// cosine retrieval and spherical poisoning defense) and normalized lexical terms (for hybrid
// Reciprocal Rank Fusion retrieval).
type MemoryRecord struct {
	ID             uint64
	Kind           string
	SourceAgent    string
	ContentDigest  [32]byte
	ProvenanceLeaf [32]byte
	Terms          []string
	UnitVec        []int64
	SalienceFixed  int64 // [0, signals.Scale]
	CreatedHeight  int64
	Quarantined    bool
	CosToCentroid  int64 // fixed-point cosine similarity vs trusted centroid at ingest time
}

// Digest returns the canonical SHA-256 digest of a MemoryRecord.
func (r MemoryRecord) Digest() [32]byte {
	out := make([]byte, 0, 192)
	out = appendString(out, DomainMemoryRecord)
	out = append(out, EncodingVersion)
	out = binary.BigEndian.AppendUint64(out, r.ID)
	out = appendString(out, r.Kind)
	out = appendString(out, r.SourceAgent)
	out = append(out, r.ContentDigest[:]...)
	out = append(out, r.ProvenanceLeaf[:]...)
	out = binary.BigEndian.AppendUint64(out, uint64(r.SalienceFixed))
	out = binary.BigEndian.AppendUint64(out, uint64(r.CreatedHeight))
	out = binary.BigEndian.AppendUint32(out, uint32(len(r.UnitVec)))
	for _, v := range r.UnitVec {
		out = binary.BigEndian.AppendUint64(out, uint64(v))
	}
	return sha256.Sum256(out)
}

// MemoryIngestReceipt proves whether a candidate memory was admitted or quarantined by the
// spherical poisoning firewall, without floating-point nondeterminism.
type MemoryIngestReceipt struct {
	RecordID           uint64
	RecordDigest       [32]byte
	Admitted           bool
	Quarantined        bool
	ReasonCode         string
	CosToCentroidFixed int64
	CoherenceFixed     int64
}

// ScoredMemory pairs a retrieved MemoryRecord with its deterministic hybrid scores.
type ScoredMemory struct {
	Record       MemoryRecord
	DenseFixed   int64
	LexicalFixed int64
	RRFFixed     int64
	FinalFixed   int64
}

// MemoryRecallProof cryptographically binds a deterministic Top-K hybrid retrieval result
// into an agent's PolicyInputProjection.ContextDigest and RFC 6962 evidence log.
type MemoryRecallProof struct {
	VaultID          string
	QueryDigest      [32]byte
	Height           int64
	CandidateCount   uint64
	QuarantinedCount uint64
	ReturnedIDs      []uint64
	ReturnedDigests  [][32]byte
	BatchCoherence   int64
}

// Digest returns SHA-256 over the canonical encoding of MemoryRecallProof.
func (p MemoryRecallProof) Digest() [32]byte {
	out := make([]byte, 0, 160+len(p.ReturnedDigests)*40)
	out = appendString(out, DomainMemoryRecall)
	out = append(out, EncodingVersion)
	out = appendString(out, p.VaultID)
	out = append(out, p.QueryDigest[:]...)
	out = binary.BigEndian.AppendUint64(out, uint64(p.Height))
	out = binary.BigEndian.AppendUint64(out, p.CandidateCount)
	out = binary.BigEndian.AppendUint64(out, p.QuarantinedCount)
	out = binary.BigEndian.AppendUint64(out, uint64(p.BatchCoherence))
	out = binary.BigEndian.AppendUint32(out, uint32(len(p.ReturnedIDs)))
	for i, id := range p.ReturnedIDs {
		out = binary.BigEndian.AppendUint64(out, id)
		out = append(out, p.ReturnedDigests[i][:]...)
	}
	return sha256.Sum256(out)
}

// MemoryVaultConfig configures a consensus-safe Governed MemoryVault.
type MemoryVaultConfig struct {
	VaultID                  string
	QuarantineThresholdFixed int64   // minimum cosine vs trusted centroid in [-Scale, Scale]; default 550000 (0.55)
	MinTrustedAnchors        int     // records required before centroid quarantine activates; default 2
	HalfLifeBlocks           int64   // linear-decay half-life in blocks (0 = no decay)
	RRFK                     int64   // Reciprocal Rank Fusion k constant (default 60)
	MaxActiveRecords         int     // bounded capacity for deterministic GnoVM gas (default 256)
	EnableColdStartGuard     bool    // guards k=1->k=2 via variance-calibrated tau^2 pairwise cosine (Experiment E6b)
	GenesisAnchor            []int64 // optional owner-pinned domain unit anchor guarding k=1..2 at full tau (Experiment E6b)
	ConeRef                  []int64   // optional anisotropic common-cone reference for fixed-point CAR debiasing (Experiment E9)
	ConeWeightFixed          int64     // CAR cone subtraction weight in [0, Scale] (e.g. 780000 = 0.78; Experiment E9)
	DispersionGateFixed      int64     // dense margin floor below which lexical RRF boosts 2x (default 80000 when CAR active)
	EnableHubnessNorm        bool      // z-score normalizes dense similarity per record against calibration block (Experiment E13a)
	HubnessMinStdFixed       int64     // std floor for HubnessNormalizeFixed (default 50000 = 0.05)
}

// MemoryVault is a consensus-safe, poison-resistant episodic/semantic memory store for Gno
// agents and Familiars. It guards writes with an ingestion-time spherical quarantine gate
// and answers queries with deterministic fixed-point Hybrid RRF (Dense Cosine + Lexical).
type MemoryVault struct {
	cfg           MemoryVaultConfig
	nextID        uint64
	dim           int
	centroidSum   []int64
	genesisUnit   []int64
	coneUnit      []int64
	hubCalUnits   [][]int64
	active        []MemoryRecord
	quarantined   []MemoryRecord
	vaultRootHash [32]byte
}

// NewMemoryVault creates a governed deterministic MemoryVault.
func NewMemoryVault(cfg MemoryVaultConfig) *MemoryVault {
	if cfg.VaultID == "" {
		cfg.VaultID = "memory-vault-v1"
	}
	if cfg.QuarantineThresholdFixed == 0 {
		cfg.QuarantineThresholdFixed = 550000 // 0.55 cosine alignment floor
	}
	if cfg.MinTrustedAnchors <= 0 {
		cfg.MinTrustedAnchors = 2
	}
	if cfg.RRFK <= 0 {
		cfg.RRFK = DefaultRRFK
	}
	if cfg.MaxActiveRecords <= 0 {
		cfg.MaxActiveRecords = 256
	}
	v := &MemoryVault{cfg: cfg}
	if len(cfg.ConeRef) > 0 && cfg.ConeWeightFixed > 0 {
		if cu, err := signals.UnitNormalizeFixed(cfg.ConeRef); err == nil {
			v.coneUnit = cu
			if v.cfg.DispersionGateFixed <= 0 {
				v.cfg.DispersionGateFixed = 80000 // 0.08 dense margin floor
			}
		}
	}
	if len(cfg.GenesisAnchor) > 0 {
		if gu, err := v.prepareUnit(cfg.GenesisAnchor); err == nil {
			v.genesisUnit = gu
		}
	}
	return v
}

func (v *MemoryVault) prepareUnit(vec []int64) ([]int64, error) {
	if len(v.coneUnit) > 0 && v.cfg.ConeWeightFixed > 0 {
		return signals.CommonAverageReferenceDebiasFixed(vec, v.coneUnit, v.cfg.ConeWeightFixed)
	}
	return signals.UnitNormalizeFixed(vec)
}

// SetHubnessCalibration registers a calibration query block and enables hubness z-score
// normalization during RetrieveTopK (Experiment E13a, Radovanovic et al. JMLR 2010 / Utah P3).
func (v *MemoryVault) SetHubnessCalibration(calibrationQueries [][]int64, minStdFixed int64) error {
	units := make([][]int64, 0, len(calibrationQueries))
	for _, q := range calibrationQueries {
		u, err := v.prepareUnit(q)
		if err != nil {
			return err
		}
		units = append(units, u)
	}
	v.hubCalUnits = units
	v.cfg.EnableHubnessNorm = true
	if minStdFixed > 0 {
		v.cfg.HubnessMinStdFixed = minStdFixed
	}
	return nil
}

// ActiveCount returns the number of admitted trusted memory records.
func (v *MemoryVault) ActiveCount() int { return len(v.active) }

// QuarantinedCount returns the number of blocked/quarantined memory records.
func (v *MemoryVault) QuarantinedCount() int { return len(v.quarantined) }

// RootHash returns the rolling SHA-256 commitment over all admitted records.
func (v *MemoryVault) RootHash() [32]byte { return v.vaultRootHash }

// ActiveEmbeddings returns copies of active unit vectors for downstream coherence checks.
func (v *MemoryVault) ActiveEmbeddings() [][]int64 {
	out := make([][]int64, len(v.active))
	for i := range v.active {
		out[i] = v.active[i].UnitVec
	}
	return out
}

// CosineFixed computes the deterministic fixed-point dot product of two unit-normalized
// vectors (each scaled to signals.Scale), returning a value in [-Scale, +Scale].
func CosineFixed(u, w []int64) (int64, error) {
	if len(u) == 0 || len(u) != len(w) {
		return 0, errors.New("vectors must be non-empty and have matching dimensions")
	}
	var sum int64
	for i := range u {
		sum += signals.MulFixed(u[i], w[i])
	}
	if sum > signals.Scale {
		sum = signals.Scale
	}
	if sum < -signals.Scale {
		sum = -signals.Scale
	}
	return sum, nil
}

// NormalizeTerms extracts deterministic deduplicated lowercase alphanumeric tokens.
func NormalizeTerms(text string) []string {
	low := strings.ToLower(text)
	var tokens []string
	var cur []byte
	for i := 0; i < len(low); i++ {
		c := low[i]
		isAlnum := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		if isAlnum {
			cur = append(cur, c)
		} else if len(cur) > 0 {
			if len(cur) >= 2 {
				tokens = appendUniqueTerm(tokens, string(cur))
			}
			cur = cur[:0]
		}
	}
	if len(cur) >= 2 {
		tokens = appendUniqueTerm(tokens, string(cur))
	}
	return tokens
}

func appendUniqueTerm(list []string, term string) []string {
	for _, existing := range list {
		if existing == term {
			return list
		}
	}
	return append(list, term)
}

func (v *MemoryVault) trustedCentroidUnit() ([]int64, bool) {
	if len(v.active) == 0 || len(v.centroidSum) == 0 {
		return nil, false
	}
	u, err := signals.UnitNormalizeFixed(v.centroidSum)
	if err != nil {
		return nil, false
	}
	return u, true
}

// Ingest validates, unit-normalizes, and runs the spherical quarantine firewall before
// admitting a memory record. Adversarial off-manifold memories are quarantined immediately
// so they never contaminate the centroid or Top-K retrieval.
func (v *MemoryVault) Ingest(
	kind string,
	sourceAgent string,
	content []byte,
	embedding []int64,
	salienceFixed int64,
	height int64,
	provenanceLeaf [32]byte,
) (MemoryIngestReceipt, error) {
	if kind == "" {
		kind = MemoryKindEpisodic
	}
	unit, err := v.prepareUnit(embedding)
	if err != nil {
		return MemoryIngestReceipt{}, err
	}
	if v.dim == 0 {
		v.dim = len(unit)
		v.centroidSum = make([]int64, v.dim)
	} else if len(unit) != v.dim {
		return MemoryIngestReceipt{}, errors.New("embedding dimension mismatch for memory vault")
	}
	if salienceFixed <= 0 {
		salienceFixed = signals.Scale
	}
	if salienceFixed > signals.Scale {
		salienceFixed = signals.Scale
	}

	v.nextID++
	rec := MemoryRecord{
		ID:             v.nextID,
		Kind:           kind,
		SourceAgent:    sourceAgent,
		ContentDigest:  HashBytes(content),
		ProvenanceLeaf: provenanceLeaf,
		Terms:          NormalizeTerms(string(content)),
		UnitVec:        unit,
		SalienceFixed:  salienceFixed,
		CreatedHeight:  height,
		CosToCentroid:  signals.Scale,
	}

	coherence := signals.Scale
	if v.cfg.QuarantineThresholdFixed > -signals.Scale {
		var refUnit []int64
		thresh := v.cfg.QuarantineThresholdFixed
		reason := "MEMORY_SPHERICAL_QUARANTINE"
		hasRef := false

		// 1. Owner-pinned GenesisAnchor guards cold-start k=1..2 at full threshold (Experiment E6b).
		if len(v.genesisUnit) == v.dim && len(v.active) < v.cfg.MinTrustedAnchors {
			refUnit = v.genesisUnit
			reason = "MEMORY_COLD_START_GENESIS_QUARANTINE"
			hasRef = true
		} else if v.cfg.EnableColdStartGuard && len(v.active) == 1 && v.cfg.MinTrustedAnchors >= 2 {
			// 2. Variance-calibrated pairwise guard (tau^2) closes the k=1->k=2 base-case gap (Experiment E6b).
			refUnit = v.active[0].UnitVec
			if thresh > 0 {
				thresh = signals.MulFixed(thresh, thresh)
			}
			reason = "MEMORY_COLD_START_PAIRWISE_QUARANTINE"
			hasRef = true
		} else if len(v.active) >= v.cfg.MinTrustedAnchors {
			if centroid, ok := v.trustedCentroidUnit(); ok {
				refUnit = centroid
				hasRef = true
			}
		}

		if hasRef {
			cos, cErr := CosineFixed(unit, refUnit)
			if cErr != nil {
				return MemoryIngestReceipt{}, cErr
			}
			rec.CosToCentroid = cos
			coherence = cos
			if cos < thresh {
				rec.Quarantined = true
				v.quarantined = append(v.quarantined, rec)
				return MemoryIngestReceipt{
					RecordID:           rec.ID,
					RecordDigest:       rec.Digest(),
					Admitted:           false,
					Quarantined:        true,
					ReasonCode:         reason,
					CosToCentroidFixed: cos,
					CoherenceFixed:     coherence,
				}, nil
			}
		}
	}

	// Evict oldest active entry if vault reached MaxActiveRecords (updating centroid sum cleanly).
	if len(v.active) >= v.cfg.MaxActiveRecords {
		evicted := v.active[0]
		v.active = v.active[1:]
		for j := 0; j < v.dim; j++ {
			v.centroidSum[j] -= evicted.UnitVec[j]
		}
	}

	v.active = append(v.active, rec)
	for j := 0; j < v.dim; j++ {
		v.centroidSum[j] += unit[j]
	}

	recDig := rec.Digest()
	var buf [64]byte
	copy(buf[:32], v.vaultRootHash[:])
	copy(buf[32:], recDig[:])
	v.vaultRootHash = sha256.Sum256(buf[:])

	return MemoryIngestReceipt{
		RecordID:           rec.ID,
		RecordDigest:       recDig,
		Admitted:           true,
		Quarantined:        false,
		ReasonCode:         "MEMORY_ADMITTED",
		CosToCentroidFixed: rec.CosToCentroid,
		CoherenceFixed:     coherence,
	}, nil
}

// RetrieveTopK performs deterministic fixed-point Hybrid Retrieval combining:
//  1. Quantized Dense Cosine Similarity (weighted by salience)
//  2. Deterministic Lexical Token-Overlap Score (exact ID/term matching)
//  3. Reciprocal Rank Fusion (RRF, k = 60) + optional integer recency decay
//
// Returns the Top-K scored records and a canonical MemoryRecallProof ready to bind into
// Agent.Execute / PolicyInputProjection.ContextDigest.
func (v *MemoryVault) RetrieveTopK(
	queryEmbedding []int64,
	queryText string,
	k int,
	currentHeight int64,
) ([]ScoredMemory, MemoryRecallProof, error) {
	if k <= 0 {
		return nil, MemoryRecallProof{}, errors.New("k must be positive")
	}
	qUnit, err := v.prepareUnit(queryEmbedding)
	if err != nil {
		return nil, MemoryRecallProof{}, err
	}
	if v.dim > 0 && len(qUnit) != v.dim {
		return nil, MemoryRecallProof{}, errors.New("query embedding dimension mismatch")
	}

	qTerms := NormalizeTerms(queryText)
	qHashInput := make([]byte, 0, len(queryText)+len(qUnit)*8)
	qHashInput = append(qHashInput, []byte(queryText)...)
	for _, x := range qUnit {
		qHashInput = binary.BigEndian.AppendUint64(qHashInput, uint64(x))
	}
	qDigest := sha256.Sum256(qHashInput)

	n := len(v.active)
	if n == 0 {
		return nil, MemoryRecallProof{
			VaultID:          v.cfg.VaultID,
			QueryDigest:      qDigest,
			Height:           currentHeight,
			CandidateCount:   0,
			QuarantinedCount: uint64(len(v.quarantined)),
			BatchCoherence:   0,
		}, nil
	}

	// Compute dense (optionally hubness z-score normalized, Experiment E13a) and lexical scores.
	denseScores := make([]int64, n)
	lexScores := make([]int64, n)
	denseOrder := make([]int, n)
	lexOrder := make([]int, n)

	var peerUnits [][]int64
	if v.cfg.EnableHubnessNorm && len(v.hubCalUnits) == 0 && n >= 4 {
		peerUnits = v.ActiveEmbeddings()
	}

	for i := 0; i < n; i++ {
		rec := v.active[i]
		var dense int64
		if v.cfg.EnableHubnessNorm && (len(v.hubCalUnits) > 0 || len(peerUnits) >= 4) {
			cal := v.hubCalUnits
			excludeIdx := -1
			if len(cal) == 0 {
				cal = peerUnits
				excludeIdx = i
			}
			stats, sErr := signals.FitHubStatsFixed(cal, rec.UnitVec, excludeIdx, v.cfg.HubnessMinStdFixed)
			if sErr != nil {
				return nil, MemoryRecallProof{}, sErr
			}
			zScore, zErr := signals.HubNormalizeScoreFixed(qUnit, rec.UnitVec, stats, v.cfg.HubnessMinStdFixed)
			if zErr != nil {
				return nil, MemoryRecallProof{}, zErr
			}
			dense = signals.MulFixed(zScore, rec.SalienceFixed)
		} else {
			cos, cErr := CosineFixed(qUnit, rec.UnitVec)
			if cErr != nil {
				return nil, MemoryRecallProof{}, cErr
			}
			dense = signals.MulFixed(cos, rec.SalienceFixed)
		}
		denseScores[i] = dense
		lexScores[i] = lexicalOverlapFixed(qTerms, rec.Terms)
		denseOrder[i] = i
		lexOrder[i] = i
	}

	// Deterministic insertion sort (descending score, tie-break by smaller Record.ID).
	sortOrderDesc(denseOrder, denseScores, v.active)
	sortOrderDesc(lexOrder, lexScores, v.active)

	denseRank := make([]int, n)
	lexRank := make([]int, n)
	for rank := 0; rank < n; rank++ {
		denseRank[denseOrder[rank]] = rank + 1
		lexRank[lexOrder[rank]] = rank + 1
	}

	// Overlap-Weighted Reciprocal Rank Fusion (RRF, k = cfg.RRFK) + Dispersion Gating + recency decay.
	// Weighting the lexical RRF term by fractional query-term coverage preserves exact-ID
	// precision on small-to-medium vaults, and when DispersionGateFixed is configured and dense
	// spread (max - median) collapses under anisotropy, lexical weight boosts 2x (Experiment E9).
	lexBoost := int64(1)
	if v.cfg.DispersionGateFixed > 0 && n >= 2 {
		maxDense := denseScores[denseOrder[0]]
		medDense := denseScores[denseOrder[n/2]]
		if maxDense-medDense < v.cfg.DispersionGateFixed {
			lexBoost = 2
		}
	}
	scored := make([]ScoredMemory, n)
	rrfK := v.cfg.RRFK
	for i := 0; i < n; i++ {
		rec := v.active[i]
		rrfDense := signals.Scale / (rrfK + int64(denseRank[i]))
		rrfLex := int64(0)
		if lexScores[i] > 0 {
			rrfLex = lexBoost * signals.MulFixed(signals.Scale/(rrfK+int64(lexRank[i])), lexScores[i])
		}
		rrf := rrfDense + rrfLex

		finalScore := rrf
		if v.cfg.HalfLifeBlocks > 0 && currentHeight > rec.CreatedHeight {
			age := currentHeight - rec.CreatedHeight
			// Smooth fixed-point decay: score * HalfLife / (HalfLife + age)
			finalScore = (rrf * v.cfg.HalfLifeBlocks) / (v.cfg.HalfLifeBlocks + age)
		}

		scored[i] = ScoredMemory{
			Record:       rec,
			DenseFixed:   denseScores[i],
			LexicalFixed: lexScores[i],
			RRFFixed:     rrf,
			FinalFixed:   finalScore,
		}
	}

	// Sort scored memories deterministically by FinalFixed desc, DenseFixed desc, ID asc.
	for i := 1; i < len(scored); i++ {
		cur := scored[i]
		j := i - 1
		for j >= 0 && scoredLess(scored[j], cur) {
			scored[j+1] = scored[j]
			j--
		}
		scored[j+1] = cur
	}

	if k > len(scored) {
		k = len(scored)
	}
	top := scored[:k]

	ids := make([]uint64, k)
	digests := make([][32]byte, k)
	vecs := make([][]int64, k)
	for i := 0; i < k; i++ {
		ids[i] = top[i].Record.ID
		digests[i] = top[i].Record.Digest()
		vecs[i] = top[i].Record.UnitVec
	}

	batchCoherence := signals.Scale
	if k >= 2 {
		if rVal, rErr := signals.MeanResultantLengthFixed(vecs); rErr == nil {
			batchCoherence = rVal
		}
	}

	proof := MemoryRecallProof{
		VaultID:          v.cfg.VaultID,
		QueryDigest:      qDigest,
		Height:           currentHeight,
		CandidateCount:   uint64(n),
		QuarantinedCount: uint64(len(v.quarantined)),
		ReturnedIDs:      ids,
		ReturnedDigests:  digests,
		BatchCoherence:   batchCoherence,
	}
	return top, proof, nil
}

func lexicalOverlapFixed(qTerms, docTerms []string) int64 {
	if len(qTerms) == 0 || len(docTerms) == 0 {
		return 0
	}
	var hits int64
	for _, qt := range qTerms {
		for _, dt := range docTerms {
			if qt == dt {
				hits++
				break
			}
		}
	}
	if hits == 0 {
		return 0
	}
	return (hits * signals.Scale) / int64(len(qTerms))
}

func sortOrderDesc(order []int, scores []int64, records []MemoryRecord) {
	for i := 1; i < len(order); i++ {
		idx := order[i]
		j := i - 1
		for j >= 0 {
			prev := order[j]
			if scores[prev] < scores[idx] || (scores[prev] == scores[idx] && records[prev].ID > records[idx].ID) {
				order[j+1] = prev
				j--
			} else {
				break
			}
		}
		order[j+1] = idx
	}
}

func scoredLess(a, b ScoredMemory) bool {
	if a.FinalFixed != b.FinalFixed {
		return a.FinalFixed < b.FinalFixed
	}
	if a.DenseFixed != b.DenseFixed {
		return a.DenseFixed < b.DenseFixed
	}
	return a.Record.ID > b.Record.ID
}

// ExecuteWithMemory retrieves Top-K memories from vault, binds the deterministic
// MemoryRecallProof digest into ContextDigest, optionally stages retrieved vectors into
// coherenceGuard, and executes the governed action with full RFC 6962 evidence.
func (a *Agent) ExecuteWithMemory(
	vault *MemoryVault,
	coherenceGuard *CoherenceGuardPolicy,
	caller string,
	action string,
	target string,
	input []byte,
	queryEmbedding []int64,
	queryText string,
	topK int,
	budgetUgnot int64,
	height int64,
) ([]byte, EvidenceBundle, MemoryRecallProof, error) {
	if vault == nil {
		return nil, EvidenceBundle{}, MemoryRecallProof{}, errors.New("memory vault cannot be nil")
	}
	top, proof, err := vault.RetrieveTopK(queryEmbedding, queryText, topK, height)
	if err != nil {
		return nil, EvidenceBundle{}, MemoryRecallProof{}, err
	}
	if coherenceGuard != nil && len(top) >= 2 {
		vecs := make([][]int64, len(top))
		for i := range top {
			vecs[i] = top[i].Record.UnitVec
		}
		if _, _, _, sErr := coherenceGuard.StageContext(vecs); sErr != nil {
			return nil, EvidenceBundle{}, proof, sErr
		}
	}
	pDig := proof.Digest()
	out, bundle, execErr := a.Execute(caller, action, target, input, pDig[:], budgetUgnot, height)
	return out, bundle, proof, execErr
}

// AuditAndPurgeWithGeometricMedian computes the deterministic fixed-point L1 Geometric Median
// (50% breakdown point) over all currently active memories and quarantines any record whose
// alignment to the geometric median falls below thresholdFixed. Returns count of purged records.
func (v *MemoryVault) AuditAndPurgeWithGeometricMedian(thresholdFixed int64) (int, error) {
	if len(v.active) < 3 {
		return 0, nil
	}
	vecs := make([][]int64, len(v.active))
	for i := range v.active {
		vecs[i] = v.active[i].UnitVec
	}
	gm, err := signals.GeometricMedianNormalizedFixed(vecs, 8)
	if err != nil {
		return 0, err
	}
	var kept []MemoryRecord
	newSum := make([]int64, v.dim)
	purged := 0
	for i := range v.active {
		rec := v.active[i]
		cos, cErr := CosineFixed(rec.UnitVec, gm)
		if cErr != nil {
			return purged, cErr
		}
		if cos < thresholdFixed {
			rec.Quarantined = true
			rec.CosToCentroid = cos
			v.quarantined = append(v.quarantined, rec)
			purged++
			continue
		}
		kept = append(kept, rec)
		for j := 0; j < v.dim; j++ {
			newSum[j] += rec.UnitVec[j]
		}
	}
	v.active = kept
	v.centroidSum = newSum
	return purged, nil
}

// AuditAntipodalSplit evaluates the active memory vault for balanced 180-degree / opposing
// split-brain poisoning using AntipodalSplitGate (Experiment E7b).
func (v *MemoryVault) AuditAntipodalSplit(negThresholdFixed, maxFractionFixed int64) (bool, int64, signals.SignalEvidence, error) {
	if len(v.active) < 2 {
		return true, 0, signals.SignalEvidence{Primitive: "signals.antipodal_split_gate", Version: "1", Detail: "insufficient_records"}, nil
	}
	vecs := v.ActiveEmbeddings()
	return signals.AntipodalSplitGate(vecs, negThresholdFixed, maxFractionFixed)
}
