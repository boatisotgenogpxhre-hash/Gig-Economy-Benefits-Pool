;; title: benefits-contribution-calculator
;; version: 1.0.0
;; summary: Automated health insurance and retirement contributions based on earnings
;; description: Smart contract for calculating and managing benefits contributions for gig workers

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-INVALID-WORKER (err u201))
(define-constant ERR-INVALID-AMOUNT (err u202))
(define-constant ERR-INSUFFICIENT-FUNDS (err u203))
(define-constant ERR-CONTRIBUTION-EXISTS (err u204))
(define-constant ERR-NOT-FOUND (err u205))
(define-constant ERR-INVALID-RATE (err u206))
(define-constant ERR-CALCULATION-ERROR (err u207))

;; Contract owner
(define-constant CONTRACT-OWNER tx-sender)

;; Contribution rate constants (in basis points, 10000 = 100%)
(define-constant DEFAULT-HEALTH-RATE u800)    ;; 8% for health insurance
(define-constant DEFAULT-RETIREMENT-RATE u600) ;; 6% for retirement
(define-constant MIN-EARNINGS-THRESHOLD u100000000) ;; 1000 STX minimum earnings
(define-constant MAX-CONTRIBUTION-RATE u1500) ;; 15% maximum total rate

;; Worker contribution profiles
(define-map worker-contributions
    { worker: principal }
    {
        total-health-contributions: uint,
        total-retirement-contributions: uint,
        current-period-earnings: uint,
        health-contribution-rate: uint,
        retirement-contribution-rate: uint,
        last-calculation-block: uint,
        is-enrolled: bool,
        enrollment-date: uint
    }
)

;; Monthly contribution tracking
(define-map monthly-contributions
    { worker: principal, month: uint, year: uint }
    {
        earnings-basis: uint,
        health-contribution: uint,
        retirement-contribution: uint,
        total-contribution: uint,
        calculation-date: uint,
        is-paid: bool
    }
)

;; Benefits pool balances
(define-map pool-balances
    { pool-type: (string-ascii 20) }
    {
        total-balance: uint,
        total-contributors: uint,
        monthly-inflows: uint,
        monthly-outflows: uint,
        reserve-ratio: uint
    }
)

;; Contribution rate tiers based on earnings
(define-map contribution-tiers
    { tier-level: uint }
    {
        min-earnings: uint,
        max-earnings: uint,
        health-rate: uint,
        retirement-rate: uint,
        tier-name: (string-ascii 50)
    }
)

;; Worker earnings history for calculation
(define-map earnings-history
    { worker: principal }
    {
        last-30-days: uint,
        last-90-days: uint,
        last-180-days: uint,
        average-monthly: uint,
        earnings-trend: int
    }
)

;; Global system variables
(define-data-var total-enrolled-workers uint u0)
(define-data-var health-pool-balance uint u0)
(define-data-var retirement-pool-balance uint u0)
(define-data-var system-reserve-ratio uint u2000) ;; 20% reserve ratio
(define-data-var contribution-adjustment-factor uint u10000) ;; 100% base rate

;; Initialize contribution tiers
(define-private (initialize-contribution-tiers)
    (begin
        ;; Tier 1: Low earners
        (map-set contribution-tiers
            {tier-level: u1}
            {
                min-earnings: u0,
                max-earnings: u500000000, ;; 5000 STX
                health-rate: u600,        ;; 6%
                retirement-rate: u400,    ;; 4%
                tier-name: "basic"
            }
        )
        ;; Tier 2: Medium earners
        (map-set contribution-tiers
            {tier-level: u2}
            {
                min-earnings: u500000000,  ;; 5000 STX
                max-earnings: u1500000000, ;; 15000 STX
                health-rate: u800,         ;; 8%
                retirement-rate: u600,     ;; 6%
                tier-name: "standard"
            }
        )
        ;; Tier 3: High earners
        (map-set contribution-tiers
            {tier-level: u3}
            {
                min-earnings: u1500000000, ;; 15000 STX
                max-earnings: u999999999999999, ;; No upper limit
                health-rate: u1000,        ;; 10%
                retirement-rate: u800,     ;; 8%
                tier-name: "premium"
            }
        )
    )
)

;; Enroll worker in benefits program
(define-public (enroll-worker)
    (let
        (
            (existing-profile (map-get? worker-contributions {worker: tx-sender}))
        )
        (asserts! (is-none existing-profile) ERR-CONTRIBUTION-EXISTS)
        
        (map-set worker-contributions
            {worker: tx-sender}
            {
                total-health-contributions: u0,
                total-retirement-contributions: u0,
                current-period-earnings: u0,
                health-contribution-rate: DEFAULT-HEALTH-RATE,
                retirement-contribution-rate: DEFAULT-RETIREMENT-RATE,
                last-calculation-block: stacks-block-height,
                is-enrolled: true,
                enrollment-date: stacks-block-height
            }
        )
        
        (var-set total-enrolled-workers (+ (var-get total-enrolled-workers) u1))
        (ok true)
    )
)

;; Calculate contributions based on earnings and tier
(define-public (calculate-contributions (worker principal) (earnings uint))
    (let
        (
            (worker-profile (unwrap! (map-get? worker-contributions {worker: worker}) ERR-INVALID-WORKER))
            (tier-info (unwrap! (get-worker-tier earnings) ERR-CALCULATION-ERROR))
            (health-rate (get health-rate tier-info))
            (retirement-rate (get retirement-rate tier-info))
            (adjustment-factor (var-get contribution-adjustment-factor))
        )
        
        (asserts! (get is-enrolled worker-profile) ERR-INVALID-WORKER)
        (asserts! (>= earnings MIN-EARNINGS-THRESHOLD) ERR-INVALID-AMOUNT)
        
        (let
            (
                (adjusted-health-rate (/ (* health-rate adjustment-factor) u10000))
                (adjusted-retirement-rate (/ (* retirement-rate adjustment-factor) u10000))
                (health-contribution (/ (* earnings adjusted-health-rate) u10000))
                (retirement-contribution (/ (* earnings adjusted-retirement-rate) u10000))
                (total-contribution (+ health-contribution retirement-contribution))
            )
            
            ;; Update worker profile with new contributions
            (map-set worker-contributions
                {worker: worker}
                {
                    total-health-contributions: (+ (get total-health-contributions worker-profile) health-contribution),
                    total-retirement-contributions: (+ (get total-retirement-contributions worker-profile) retirement-contribution),
                    current-period-earnings: earnings,
                    health-contribution-rate: adjusted-health-rate,
                    retirement-contribution-rate: adjusted-retirement-rate,
                    last-calculation-block: stacks-block-height,
                    is-enrolled: true,
                    enrollment-date: (get enrollment-date worker-profile)
                }
            )
            
            ;; Update pool balances
            (var-set health-pool-balance (+ (var-get health-pool-balance) health-contribution))
            (var-set retirement-pool-balance (+ (var-get retirement-pool-balance) retirement-contribution))
            
            (ok {
                health-contribution: health-contribution,
                retirement-contribution: retirement-contribution,
                total-contribution: total-contribution,
                tier-level: (get-tier-level earnings)
            })
        )
    )
)

;; Process monthly contributions for a worker
(define-public (process-monthly-contribution (worker principal) (month uint) (year uint) (earnings uint))
    (let
        (
            (contribution-calc (unwrap! (calculate-contributions worker earnings) ERR-CALCULATION-ERROR))
            (existing-monthly (map-get? monthly-contributions {worker: worker, month: month, year: year}))
        )
        
        (asserts! (is-none existing-monthly) ERR-CONTRIBUTION-EXISTS)
        
        (map-set monthly-contributions
            {worker: worker, month: month, year: year}
            {
                earnings-basis: earnings,
                health-contribution: (get health-contribution contribution-calc),
                retirement-contribution: (get retirement-contribution contribution-calc),
                total-contribution: (get total-contribution contribution-calc),
                calculation-date: stacks-block-height,
                is-paid: false
            }
        )
        
        (ok contribution-calc)
    )
)

;; Mark monthly contribution as paid
(define-public (mark-contribution-paid (worker principal) (month uint) (year uint))
    (let
        (
            (monthly-data (unwrap! (map-get? monthly-contributions {worker: worker, month: month, year: year}) ERR-NOT-FOUND))
        )
        
        (asserts! (not (get is-paid monthly-data)) ERR-INVALID-AMOUNT)
        
        (map-set monthly-contributions
            {worker: worker, month: month, year: year}
            {
                earnings-basis: (get earnings-basis monthly-data),
                health-contribution: (get health-contribution monthly-data),
                retirement-contribution: (get retirement-contribution monthly-data),
                total-contribution: (get total-contribution monthly-data),
                calculation-date: (get calculation-date monthly-data),
                is-paid: true
            }
        )
        
        (ok true)
    )
)

;; Get worker contribution profile
(define-read-only (get-worker-profile (worker principal))
    (match (map-get? worker-contributions {worker: worker})
        profile (ok profile)
        ERR-NOT-FOUND
    )
)

;; Get monthly contribution details
(define-read-only (get-monthly-contribution (worker principal) (month uint) (year uint))
    (match (map-get? monthly-contributions {worker: worker, month: month, year: year})
        contribution (ok contribution)
        ERR-NOT-FOUND
    )
)

;; Determine worker's contribution tier based on earnings
(define-read-only (get-worker-tier (earnings uint))
    (if (<= earnings u500000000)
        (map-get? contribution-tiers {tier-level: u1})
        (if (<= earnings u1500000000)
            (map-get? contribution-tiers {tier-level: u2})
            (map-get? contribution-tiers {tier-level: u3})
        )
    )
)

;; Get tier level number for earnings
(define-read-only (get-tier-level (earnings uint))
    (if (<= earnings u500000000)
        u1
        (if (<= earnings u1500000000)
            u2
            u3
        )
    )
)

;; Calculate projected annual contributions
(define-read-only (calculate-annual-projection (worker principal) (monthly-earnings uint))
    (let
        (
            (tier-info (unwrap! (get-worker-tier monthly-earnings) ERR-CALCULATION-ERROR))
            (annual-earnings (* monthly-earnings u12))
            (health-rate (get health-rate tier-info))
            (retirement-rate (get retirement-rate tier-info))
        )
        
        (let
            (
                (annual-health (/ (* annual-earnings health-rate) u10000))
                (annual-retirement (/ (* annual-earnings retirement-rate) u10000))
            )
            
            (ok {
                projected-annual-earnings: annual-earnings,
                projected-health-contributions: annual-health,
                projected-retirement-contributions: annual-retirement,
                projected-total-contributions: (+ annual-health annual-retirement),
                tier-level: (get-tier-level monthly-earnings)
            })
        )
    )
)

;; Get pool statistics
(define-read-only (get-pool-statistics)
    (ok {
        health-pool-balance: (var-get health-pool-balance),
        retirement-pool-balance: (var-get retirement-pool-balance),
        total-enrolled-workers: (var-get total-enrolled-workers),
        system-reserve-ratio: (var-get system-reserve-ratio),
        adjustment-factor: (var-get contribution-adjustment-factor)
    })
)

;; Administrative functions
(define-public (adjust-contribution-rates (new-adjustment-factor uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (asserts! (and (>= new-adjustment-factor u5000) (<= new-adjustment-factor u20000)) ERR-INVALID-RATE)
        (var-set contribution-adjustment-factor new-adjustment-factor)
        (ok true)
    )
)

;; Update tier rates
(define-public (update-tier-rates (tier-level uint) (health-rate uint) (retirement-rate uint))
    (let
        (
            (existing-tier (unwrap! (map-get? contribution-tiers {tier-level: tier-level}) ERR-NOT-FOUND))
        )
        
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (asserts! (<= (+ health-rate retirement-rate) MAX-CONTRIBUTION-RATE) ERR-INVALID-RATE)
        
        (map-set contribution-tiers
            {tier-level: tier-level}
            {
                min-earnings: (get min-earnings existing-tier),
                max-earnings: (get max-earnings existing-tier),
                health-rate: health-rate,
                retirement-rate: retirement-rate,
                tier-name: (get tier-name existing-tier)
            }
        )
        
        (ok true)
    )
)

;; Initialize the contract
(initialize-contribution-tiers)

