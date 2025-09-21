;; title: earnings-tracking-oracle
;; version: 1.0.0
;; summary: Integration with gig platforms to track worker earnings and work hours
;; description: Smart contract for tracking gig worker earnings across multiple platforms

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-PLATFORM (err u101))
(define-constant ERR-INVALID-WORKER (err u102))
(define-constant ERR-INVALID-AMOUNT (err u103))
(define-constant ERR-ALREADY-EXISTS (err u104))
(define-constant ERR-NOT-FOUND (err u105))
(define-constant ERR-INSUFFICIENT-BALANCE (err u106))

;; Contract owner
(define-constant CONTRACT-OWNER tx-sender)

;; Data structures for worker earnings tracking
(define-map worker-profiles
    { worker: principal }
    {
        total-earnings: uint,
        total-hours: uint,
        platform-count: uint,
        registration-block: uint,
        is-active: bool
    }
)

;; Platform integration data
(define-map platform-integrations
    { platform-id: (string-ascii 50) }
    {
        platform-name: (string-ascii 100),
        api-endpoint: (string-ascii 200),
        is-verified: bool,
        integration-block: uint,
        worker-count: uint
    }
)

;; Worker earnings per platform
(define-map worker-platform-earnings
    { worker: principal, platform-id: (string-ascii 50) }
    {
        current-earnings: uint,
        total-hours-worked: uint,
        last-update-block: uint,
        earnings-history: (list 10 uint),
        average-hourly-rate: uint
    }
)

;; Daily earnings aggregation
(define-map daily-earnings
    { worker: principal, date: uint }
    {
        total-daily-earnings: uint,
        hours-worked: uint,
        platforms-active: uint,
        earnings-by-platform: (list 5 uint)
    }
)

;; Authorized platform operators
(define-map platform-operators
    { operator: principal }
    { platform-id: (string-ascii 50), is-active: bool }
)

;; Global statistics
(define-data-var total-registered-workers uint u0)
(define-data-var total-integrated-platforms uint u0)
(define-data-var total-tracked-earnings uint u0)
(define-data-var system-commission-rate uint u250) ;; 2.5% in basis points

;; Platform verification functions
(define-public (register-platform (platform-id (string-ascii 50)) 
                                (platform-name (string-ascii 100)) 
                                (api-endpoint (string-ascii 200)))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (asserts! (is-none (map-get? platform-integrations {platform-id: platform-id})) ERR-ALREADY-EXISTS)
        
        (map-set platform-integrations
            {platform-id: platform-id}
            {
                platform-name: platform-name,
                api-endpoint: api-endpoint,
                is-verified: true,
                integration-block: stacks-block-height,
                worker-count: u0
            }
        )
        
        (var-set total-integrated-platforms (+ (var-get total-integrated-platforms) u1))
        (ok true)
    )
)

;; Worker registration and management
(define-public (register-worker)
    (let
        (
            (existing-profile (map-get? worker-profiles {worker: tx-sender}))
        )
        (asserts! (is-none existing-profile) ERR-ALREADY-EXISTS)
        
        (map-set worker-profiles
            {worker: tx-sender}
            {
                total-earnings: u0,
                total-hours: u0,
                platform-count: u0,
                registration-block: stacks-block-height,
                is-active: true
            }
        )
        
        (var-set total-registered-workers (+ (var-get total-registered-workers) u1))
        (ok true)
    )
)

;; Record earnings from platform integration
(define-public (record-earnings (worker principal) 
                              (platform-id (string-ascii 50)) 
                              (earnings uint) 
                              (hours-worked uint))
    (let
        (
            (platform-info (unwrap! (map-get? platform-integrations {platform-id: platform-id}) ERR-INVALID-PLATFORM))
            (worker-profile (unwrap! (map-get? worker-profiles {worker: worker}) ERR-INVALID-WORKER))
            (existing-earnings (default-to 
                {
                    current-earnings: u0,
                    total-hours-worked: u0,
                    last-update-block: u0,
                    earnings-history: (list),
                    average-hourly-rate: u0
                } 
                (map-get? worker-platform-earnings {worker: worker, platform-id: platform-id})
            ))
        )
        
        (asserts! (> earnings u0) ERR-INVALID-AMOUNT)
        (asserts! (> hours-worked u0) ERR-INVALID-AMOUNT)
        (asserts! (get is-verified platform-info) ERR-INVALID-PLATFORM)
        (asserts! (get is-active worker-profile) ERR-INVALID-WORKER)
        
        ;; Update worker platform earnings
        (map-set worker-platform-earnings
            {worker: worker, platform-id: platform-id}
            {
                current-earnings: (+ (get current-earnings existing-earnings) earnings),
                total-hours-worked: (+ (get total-hours-worked existing-earnings) hours-worked),
                last-update-block: stacks-block-height,
                earnings-history: (unwrap! (as-max-len? (append (get earnings-history existing-earnings) earnings) u10) ERR-INVALID-AMOUNT),
                average-hourly-rate: (/ (+ (get current-earnings existing-earnings) earnings) (+ (get total-hours-worked existing-earnings) hours-worked))
            }
        )
        
        ;; Update worker profile
        (map-set worker-profiles
            {worker: worker}
            {
                total-earnings: (+ (get total-earnings worker-profile) earnings),
                total-hours: (+ (get total-hours worker-profile) hours-worked),
                platform-count: (get platform-count worker-profile),
                registration-block: (get registration-block worker-profile),
                is-active: true
            }
        )
        
        ;; Update global statistics
        (var-set total-tracked-earnings (+ (var-get total-tracked-earnings) earnings))
        
        (ok true)
    )
)

;; Get worker earnings summary
(define-read-only (get-worker-earnings (worker principal))
    (let
        (
            (profile (map-get? worker-profiles {worker: worker}))
        )
        (match profile
            worker-data (ok worker-data)
            ERR-NOT-FOUND
        )
    )
)

;; Get platform-specific earnings for a worker
(define-read-only (get-worker-platform-earnings (worker principal) (platform-id (string-ascii 50)))
    (let
        (
            (earnings-data (map-get? worker-platform-earnings {worker: worker, platform-id: platform-id}))
        )
        (match earnings-data
            earnings-info (ok earnings-info)
            ERR-NOT-FOUND
        )
    )
)

;; Calculate worker's average hourly rate across all platforms
(define-read-only (get-worker-average-rate (worker principal))
    (let
        (
            (profile (unwrap! (map-get? worker-profiles {worker: worker}) ERR-NOT-FOUND))
            (total-earnings (get total-earnings profile))
            (total-hours (get total-hours profile))
        )
        (if (> total-hours u0)
            (ok (/ total-earnings total-hours))
            (ok u0)
        )
    )
)

;; Get platform information
(define-read-only (get-platform-info (platform-id (string-ascii 50)))
    (let
        (
            (platform-data (map-get? platform-integrations {platform-id: platform-id}))
        )
        (match platform-data
            platform-info (ok platform-info)
            ERR-NOT-FOUND
        )
    )
)

;; Get system statistics
(define-read-only (get-system-stats)
    (ok {
        total-workers: (var-get total-registered-workers),
        total-platforms: (var-get total-integrated-platforms),
        total-earnings: (var-get total-tracked-earnings),
        commission-rate: (var-get system-commission-rate)
    })
)

;; Administrative functions
(define-public (update-commission-rate (new-rate uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (asserts! (<= new-rate u1000) ERR-INVALID-AMOUNT) ;; Max 10%
        (var-set system-commission-rate new-rate)
        (ok true)
    )
)

;; Deactivate a worker (admin function)
(define-public (deactivate-worker (worker principal))
    (let
        (
            (profile (unwrap! (map-get? worker-profiles {worker: worker}) ERR-NOT-FOUND))
        )
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        
        (map-set worker-profiles
            {worker: worker}
            {
                total-earnings: (get total-earnings profile),
                total-hours: (get total-hours profile),
                platform-count: (get platform-count profile),
                registration-block: (get registration-block profile),
                is-active: false
            }
        )
        (ok true)
    )
)

