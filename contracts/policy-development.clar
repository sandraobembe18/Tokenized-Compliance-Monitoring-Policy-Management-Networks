;; Policy Development System
;; Manages creation, versioning, and lifecycle of compliance policies

;; Constants
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-POLICY-NOT-FOUND (err u201))
(define-constant ERR-INVALID-STATUS (err u202))
(define-constant ERR-ALREADY-VOTED (err u203))
(define-constant ERR-VOTING-CLOSED (err u204))
(define-constant ERR-INSUFFICIENT-APPROVALS (err u205))

;; Data Variables
(define-data-var next-policy-id uint u1)
(define-data-var approval-threshold uint u60) ;; 60% approval required
(define-data-var voting-period uint u1440) ;; blocks (~10 days)

;; Policy Status Constants
(define-constant STATUS-DRAFT u1)
(define-constant STATUS-REVIEW u2)
(define-constant STATUS-VOTING u3)
(define-constant STATUS-APPROVED u4)
(define-constant STATUS-ACTIVE u5)
(define-constant STATUS-DEPRECATED u6)

;; Data Maps
(define-map policies uint {
    id: uint,
    title: (string-ascii 100),
    description: (string-ascii 500),
    category: (string-ascii 50),
    creator: principal,
    version: uint,
    status: uint,
    creation-block: uint,
    voting-start-block: (optional uint),
    voting-end-block: (optional uint),
    approval-count: uint,
    rejection-count: uint,
    implementation-deadline: uint,
    compliance-requirements: (list 10 (string-ascii 100))
})

(define-map policy-versions uint (list 10 {
    version: uint,
    changes: (string-ascii 200),
    updated-by: principal,
    update-block: uint
}))

(define-map policy-votes { policy-id: uint, voter: principal } {
    vote: bool, ;; true for approve, false for reject
    voting-power: uint,
    vote-block: uint,
    rationale: (optional (string-ascii 200))
})

(define-map stakeholder-voting-power principal uint)

(define-map policy-comments uint (list 20 {
    commenter: principal,
    comment: (string-ascii 300),
    comment-block: uint,
    comment-type: (string-ascii 20) ;; "feedback", "concern", "suggestion"
}))

;; Public Functions

;; Create a new policy
(define-public (create-policy (title (string-ascii 100))
                             (description (string-ascii 500))
                             (category (string-ascii 50))
                             (implementation-deadline uint)
                             (compliance-requirements (list 10 (string-ascii 100))))
    (let ((policy-id (var-get next-policy-id)))
        ;; Store policy data
        (map-set policies policy-id {
            id: policy-id,
            title: title,
            description: description,
            category: category,
            creator: tx-sender,
            version: u1,
            status: STATUS-DRAFT,
            creation-block: block-height,
            voting-start-block: none,
            voting-end-block: none,
            approval-count: u0,
            rejection-count: u0,
            implementation-deadline: implementation-deadline,
            compliance-requirements: compliance-requirements
        })

        ;; Initialize version history
        (map-set policy-versions policy-id (list {
            version: u1,
            changes: "Initial policy creation",
            updated-by: tx-sender,
            update-block: block-height
        }))

        ;; Increment policy ID counter
        (var-set next-policy-id (+ policy-id u1))

        (ok policy-id)))

;; Submit policy for review
(define-public (submit-for-review (policy-id uint))
    (let ((policy-data (unwrap! (map-get? policies policy-id) ERR-POLICY-NOT-FOUND)))
        (asserts! (is-eq (get creator policy-data) tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status policy-data) STATUS-DRAFT) ERR-INVALID-STATUS)

        (map-set policies policy-id
            (merge policy-data { status: STATUS-REVIEW }))

        (ok true)))

;; Start voting period (admin function)
(define-public (start-voting (policy-id uint))
    (let ((policy-data (unwrap! (map-get? policies policy-id) ERR-POLICY-NOT-FOUND))
          (voting-end (+ block-height (var-get voting-period))))
        (asserts! (is-eq (get status policy-data) STATUS-REVIEW) ERR-INVALID-STATUS)

        (map-set policies policy-id
            (merge policy-data {
                status: STATUS-VOTING,
                voting-start-block: (some block-height),
                voting-end-block: (some voting-end)
            }))

        (ok true)))

;; Cast vote on policy
(define-public (vote-on-policy (policy-id uint)
                              (vote bool)
                              (rationale (optional (string-ascii 200))))
    (let ((policy-data (unwrap! (map-get? policies policy-id) ERR-POLICY-NOT-FOUND))
          (voter-power (default-to u1 (map-get? stakeholder-voting-power tx-sender)))
          (vote-key { policy-id: policy-id, voter: tx-sender }))

        (asserts! (is-eq (get status policy-data) STATUS-VOTING) ERR-INVALID-STATUS)
        (asserts! (is-none (map-get? policy-votes vote-key)) ERR-ALREADY-VOTED)
        (asserts! (< block-height (unwrap-panic (get voting-end-block policy-data))) ERR-VOTING-CLOSED)

        ;; Record vote
        (map-set policy-votes vote-key {
            vote: vote,
            voting-power: voter-power,
            vote-block: block-height,
            rationale: rationale
        })

        ;; Update vote counts
        (if vote
            (map-set policies policy-id
                (merge policy-data {
                    approval-count: (+ (get approval-count policy-data) voter-power)
                }))
            (map-set policies policy-id
                (merge policy-data {
                    rejection-count: (+ (get rejection-count policy-data) voter-power)
                })))

        (ok true)))

;; Finalize voting and determine approval
(define-public (finalize-voting (policy-id uint))
    (let ((policy-data (unwrap! (map-get? policies policy-id) ERR-POLICY-NOT-FOUND))
          (total-votes (+ (get approval-count policy-data) (get rejection-count policy-data)))
          (approval-percentage (if (> total-votes u0)
                                  (/ (* (get approval-count policy-data) u100) total-votes)
                                  u0)))

        (asserts! (is-eq (get status policy-data) STATUS-VOTING) ERR-INVALID-STATUS)
        (asserts! (>= block-height (unwrap-panic (get voting-end-block policy-data))) ERR-VOTING-CLOSED)

        (if (>= approval-percentage (var-get approval-threshold))
            (map-set policies policy-id
                (merge policy-data { status: STATUS-APPROVED }))
            (map-set policies policy-id
                (merge policy-data { status: STATUS-DRAFT })))

        (ok approval-percentage)))

;; Activate approved policy
(define-public (activate-policy (policy-id uint))
    (let ((policy-data (unwrap! (map-get? policies policy-id) ERR-POLICY-NOT-FOUND)))
        (asserts! (is-eq (get status policy-data) STATUS-APPROVED) ERR-INVALID-STATUS)

        (map-set policies policy-id
            (merge policy-data { status: STATUS-ACTIVE }))

        (ok true)))

;; Add comment to policy
(define-public (add-comment (policy-id uint)
                           (comment (string-ascii 300))
                           (comment-type (string-ascii 20)))
    (let ((current-comments (default-to (list) (map-get? policy-comments policy-id))))
        (asserts! (is-some (map-get? policies policy-id)) ERR-POLICY-NOT-FOUND)

        (map-set policy-comments policy-id
            (unwrap-panic (as-max-len?
                (append current-comments {
                    commenter: tx-sender,
                    comment: comment,
                    comment-block: block-height,
                    comment-type: comment-type
                }) u20)))

        (ok true)))

;; Update policy version
(define-public (update-policy-version (policy-id uint)
                                     (changes (string-ascii 200)))
    (let ((policy-data (unwrap! (map-get? policies policy-id) ERR-POLICY-NOT-FOUND))
          (current-versions (default-to (list) (map-get? policy-versions policy-id)))
          (new-version (+ (get version policy-data) u1)))

        (asserts! (is-eq (get creator policy-data) tx-sender) ERR-NOT-AUTHORIZED)

        ;; Update policy version
        (map-set policies policy-id
            (merge policy-data {
                version: new-version,
                status: STATUS-DRAFT
            }))

        ;; Add to version history
        (map-set policy-versions policy-id
            (unwrap-panic (as-max-len?
                (append current-versions {
                    version: new-version,
                    changes: changes,
                    updated-by: tx-sender,
                    update-block: block-height
                }) u10)))

        (ok new-version)))

;; Read-only Functions

;; Get policy information
(define-read-only (get-policy (policy-id uint))
    (map-get? policies policy-id))

;; Get policy version history
(define-read-only (get-policy-versions (policy-id uint))
    (map-get? policy-versions policy-id))

;; Get policy comments
(define-read-only (get-policy-comments (policy-id uint))
    (map-get? policy-comments policy-id))

;; Get vote information
(define-read-only (get-vote (policy-id uint) (voter principal))
    (map-get? policy-votes { policy-id: policy-id, voter: voter }))

;; Check if policy is active
(define-read-only (is-policy-active (policy-id uint))
    (match (map-get? policies policy-id)
        policy-data (is-eq (get status policy-data) STATUS-ACTIVE)
        false))

;; Get voting results
(define-read-only (get-voting-results (policy-id uint))
    (match (map-get? policies policy-id)
        policy-data (let ((total-votes (+ (get approval-count policy-data) (get rejection-count policy-data))))
                       (some {
                           approval-count: (get approval-count policy-data),
                           rejection-count: (get rejection-count policy-data),
                           total-votes: total-votes,
                           approval-percentage: (if (> total-votes u0)
                                                   (/ (* (get approval-count policy-data) u100) total-votes)
                                                   u0)
                       }))
        none))

;; Admin Functions

;; Set stakeholder voting power
(define-public (set-voting-power (stakeholder principal) (power uint))
    (begin
        (map-set stakeholder-voting-power stakeholder power)
        (ok true)))

;; Update approval threshold
(define-public (set-approval-threshold (new-threshold uint))
    (begin
        (asserts! (<= new-threshold u100) ERR-INVALID-STATUS)
        (var-set approval-threshold new-threshold)
        (ok true)))
