import QtQuick
import QtTest
import testservices

// Behavioral tests for the parsing/derivation logic of services/OciVps.qml,
// exercised through the logic-only `OciVps` double in tests/imports/testservices.
//
// The load-bearing one is test_metered_usage_is_taken_not_derived: the panel
// exists to report an allowance, and an instance resized mid-month has spent
// more of it than its current shape implies. Anything that starts computing
// usage from ocpus × elapsed time is a regression, so the numbers are pinned
// against a document whose shape disagrees with its metered totals.
TestCase {
    name: "OciVpsTest"

    function init() {
        OciVps.configured = false
        OciVps.available = false
        OciVps.loading = false
        OciVps.lastError = ""
        OciVps.generatedAt = ""
        OciVps.name = ""
        OciVps.state = ""
        OciVps.shape = ""
        OciVps.ocpus = 0
        OciVps.memoryGb = 0
        OciVps.region = ""
        OciVps.faultDomain = ""
        OciVps.cpuPercent = -1
        OciVps.memoryPercent = -1
        OciVps.loadAverage = -1
        OciVps.ocpuMeter = ({})
        OciVps.memoryMeter = ({})
        OciVps.egressMeter = ({})
        OciVps.bootSizeGb = 0
        OciVps.bootVpusPerGb = 0
        OciVps.actionPending = false
        OciVps.pendingAction = ""
        OciVps.bootVpuBillable = false
        OciVps.dailyOcpu = []
        OciVps.dailyEgress = []
        OciVps.skus = []
    }

    function makeDocument(overrides) {
        const base = {
            "ok": true,
            "generatedAt": "2026-08-20T09:07:23+00:00",
            "instance": {
                "name": "COOLIFY",
                "state": "RUNNING",
                "shape": "VM.Standard.A1.Flex",
                "ocpus": 2,
                "memoryGb": 12,
                "region": "ap-mumbai-1",
                "faultDomain": "FAULT-DOMAIN-2"
            },
            "live": { "cpuPercent": 38.25, "memoryPercent": 61.63, "loadAverage": 1.55 },
            "freeTier": {
                "ocpu": {
                    "used": 1642.87, "limit": 3000, "percent": 54.76,
                    "projected": 2218.87, "projectedPercent": 73.96,
                    "status": "safe", "projectedStatus": "safe"
                },
                "memory": {
                    "used": 9857.2, "limit": 18000, "percent": 54.76,
                    "projected": 13313.2, "projectedPercent": 73.96,
                    "status": "safe", "projectedStatus": "safe"
                }
            },
            "egress": {
                "used": 72.89, "limit": 10000, "percent": 0.73,
                "projected": 116.59, "projectedPercent": 1.17,
                "status": "safe", "projectedStatus": "safe"
            },
            "storage": {
                "bootSizeGb": 200, "bootVpusPerGb": 10,
                "bootState": "AVAILABLE", "bootVpuBillable": false
            },
            "dailyOcpuHours": [
                { "day": "2026-08-14", "hours": 96 },
                { "day": "2026-08-15", "hours": 96 },
                { "day": "2026-08-16", "hours": 58.87 },
                { "day": "2026-08-17", "hours": 48 }
            ],
            "dailyEgressGb": [{ "day": "2026-08-17", "gb": 3.5 }],
            "skus": [{ "part": "B93297", "name": "Standard - A1", "quantity": 1642.87 }]
        }
        return JSON.stringify(Object.assign(base, overrides ?? {}))
    }

    function test_good_document_populates_state() {
        OciVps.applyStatus(makeDocument())
        compare(OciVps.available, true)
        compare(OciVps.lastError, "")
        compare(OciVps.name, "COOLIFY")
        compare(OciVps.running, true)
        compare(OciVps.ocpus, 2)
        compare(OciVps.memoryGb, 12)
        compare(OciVps.region, "ap-mumbai-1")
        compare(OciVps.bootSizeGb, 200)
        compare(OciVps.bootVpuBillable, false)
    }

    // The reason this panel reads the Usage API at all.
    function test_metered_usage_is_taken_not_derived() {
        OciVps.applyStatus(makeDocument())
        // 2 OCPU × 465h elapsed would be ~930; the box ran at 4 OCPU for half
        // the month, and Oracle's metered figure says so.
        compare(OciVps.ocpuMeter.used, 1642.87)
        compare(OciVps.memoryMeter.used, 9857.2)
        verify(OciVps.ocpuMeter.used > OciVps.ocpus * 465)
    }

    function test_absent_live_metric_is_not_zero() {
        OciVps.applyStatus(makeDocument({ "live": {} }))
        compare(OciVps.cpuPercent, -1)
        compare(OciVps.memoryPercent, -1)
        compare(OciVps.loadAverage, -1)
        compare(OciVps.hasLiveMetrics, false)
    }

    function test_reported_zero_load_is_kept() {
        OciVps.applyStatus(makeDocument({
            "live": { "cpuPercent": 0, "memoryPercent": 0, "loadAverage": 0 }
        }))
        compare(OciVps.cpuPercent, 0)
        compare(OciVps.hasLiveMetrics, true)
    }

    function test_failure_document_reports_error() {
        OciVps.applyStatus(JSON.stringify({ "ok": false, "error": "HTTP 401: NotAuthenticated" }))
        compare(OciVps.available, false)
        compare(OciVps.lastError, "HTTP 401: NotAuthenticated")
    }

    function test_malformed_response_is_survived() {
        OciVps.applyStatus("not json at all")
        compare(OciVps.available, false)
        verify(OciVps.lastError.length > 0)
    }

    function test_worst_status_escalates() {
        OciVps.applyStatus(makeDocument())
        compare(OciVps.worstStatus, "safe")

        OciVps.applyStatus(makeDocument({
            "egress": { "used": 7200, "limit": 10000, "percent": 72, "status": "critical", "projectedStatus": "critical" }
        }))
        compare(OciVps.worstStatus, "critical")
    }

    function test_worst_status_prefers_the_worst_of_three() {
        OciVps.applyStatus(makeDocument({
            "freeTier": {
                "ocpu": { "used": 1, "limit": 3000, "percent": 1, "status": "watch" },
                "memory": { "used": 1, "limit": 18000, "percent": 1, "status": "over" }
            }
        }))
        compare(OciVps.worstStatus, "over")
    }

    function test_symbol_tracks_availability_and_verdict() {
        compare(OciVps.materialSymbol, "cloud_off")
        OciVps.applyStatus(makeDocument())
        compare(OciVps.materialSymbol, "cloud_done")
        OciVps.applyStatus(makeDocument({
            "egress": { "used": 8200, "limit": 10000, "percent": 82, "status": "over" }
        }))
        compare(OciVps.materialSymbol, "cloud_alert")
    }

    // A resize must stay legible as a step, so the series is scaled against its
    // own peak rather than against the allowance.
    function test_daily_series_normalizes_against_its_peak() {
        OciVps.applyStatus(makeDocument())
        compare(OciVps.dailyOcpuPeak, 96)
        const values = OciVps.dailyOcpuNormalized
        compare(values.length, 4)
        compare(values[0], 1)
        compare(values[3], 0.5)
        verify(values[2] > 0.6 && values[2] < 0.62)
    }

    function test_empty_series_yields_no_points() {
        OciVps.applyStatus(makeDocument({ "dailyOcpuHours": [] }))
        compare(OciVps.dailyOcpuNormalized.length, 0)
        compare(OciVps.dailyOcpuPeak, 0)
    }

    function test_all_zero_series_does_not_divide_by_zero() {
        OciVps.applyStatus(makeDocument({
            "dailyOcpuHours": [{ "day": "2026-08-01", "hours": 0 }, { "day": "2026-08-02", "hours": 0 }]
        }))
        compare(OciVps.dailyOcpuNormalized.length, 0)
    }

    function test_gigabyte_formatting_crosses_units() {
        compare(OciVps.formatGb(0.25), "250 MB")
        compare(OciVps.formatGb(72.89), "72.9 GB")
        compare(OciVps.formatGb(10000), "10.00 TB")
    }

    function test_hour_formatting_keeps_small_values_precise() {
        compare(OciVps.formatHours(48), "48.0")
        compare(OciVps.formatHours(1642.87), "1,643")
    }

    function test_stopped_instance_is_not_running() {
        OciVps.applyStatus(makeDocument({
            "instance": { "name": "COOLIFY", "state": "STOPPED", "ocpus": 2, "memoryGb": 12 }
        }))
        compare(OciVps.running, false)
    }

    function test_billable_boot_volume_is_flagged() {
        OciVps.applyStatus(makeDocument({
            "storage": { "bootSizeGb": 200, "bootVpusPerGb": 20, "bootVpuBillable": true }
        }))
        compare(OciVps.bootVpuBillable, true)
        compare(OciVps.bootVpusPerGb, 20)
    }

    // The buttons must not offer an action the API would refuse, and must not
    // offer a second one while the first is in flight.
    function test_start_is_offered_only_when_stopped() {
        OciVps.applyStatus(makeDocument())
        compare(OciVps.canStart, false)
        compare(OciVps.canStop, true)
        compare(OciVps.canReboot, true)

        OciVps.applyStatus(makeDocument({
            "instance": { "name": "COOLIFY", "state": "STOPPED", "ocpus": 2, "memoryGb": 12 }
        }))
        compare(OciVps.canStart, true)
        compare(OciVps.canStop, false)
        compare(OciVps.canReboot, false)
    }

    function test_no_action_is_offered_while_one_is_pending() {
        OciVps.applyStatus(makeDocument())
        OciVps.actionPending = true
        compare(OciVps.canStop, false)
        compare(OciVps.canReboot, false)
        compare(OciVps.canStart, false)
    }

    function test_transitional_states_are_recognised() {
        OciVps.applyStatus(makeDocument({
            "instance": { "name": "COOLIFY", "state": "STOPPING", "ocpus": 2, "memoryGb": 12 }
        }))
        compare(OciVps.inTransition, true)
        compare(OciVps.running, false)
        compare(OciVps.canStop, false)
    }

    function test_action_result_adopts_the_transitional_state() {
        OciVps.applyStatus(makeDocument())
        compare(OciVps.state, "RUNNING")
        OciVps.applyActionResult(JSON.stringify({
            "ok": true, "action": "SOFTSTOP", "from": "RUNNING", "state": "STOPPING"
        }))
        compare(OciVps.state, "STOPPING")
        compare(OciVps.lastError, "")
    }

    function test_refused_action_surfaces_its_reason() {
        OciVps.applyStatus(makeDocument())
        OciVps.applyActionResult(JSON.stringify({
            "ok": false, "error": "START needs the instance to be STOPPED, not RUNNING"
        }))
        compare(OciVps.state, "RUNNING")
        compare(OciVps.lastError, "START needs the instance to be STOPPED, not RUNNING")
    }

    function test_unreadable_action_response_is_survived() {
        OciVps.applyStatus(makeDocument())
        OciVps.applyActionResult("<html>gateway timeout</html>")
        compare(OciVps.state, "RUNNING")
        verify(OciVps.lastError.length > 0)
    }

    function test_rate_formatting_crosses_units() {
        compare(OciVps.formatRate(842), "842 B/s")
        compare(OciVps.formatRate(846042), "846 kB/s")
        compare(OciVps.formatRate(2516496), "2.52 MB/s")
    }

    // A counter reset makes the rate negative; absent and negative both mean
    // "no reading", and neither may be drawn as 0 B/s.
    function test_absent_rate_is_a_dash() {
        compare(OciVps.formatRate(-1), "-")
        OciVps.applyStatus(makeDocument({ "live": { "cpuPercent": 5 } }))
        compare(OciVps.netInRate, -1)
        compare(OciVps.formatRate(OciVps.netInRate), "-")
    }

    function test_shape_extras_are_read() {
        OciVps.applyStatus(makeDocument({
            "instance": {
                "name": "COOLIFY", "state": "RUNNING", "ocpus": 2, "memoryGb": 12,
                "processor": "3.0 GHz Ampere® Altra™", "bandwidthGbps": 2, "maxVnics": 2,
                "created": "2025-08-12T04:58:18.196Z"
            }
        }))
        compare(OciVps.processor, "3.0 GHz Ampere® Altra™")
        compare(OciVps.bandwidthGbps, 2)
        compare(OciVps.maxVnics, 2)
        compare(OciVps.created.slice(0, 10), "2025-08-12")
    }

    // Boot and block share one 200 GB allowance, so a full allocation is a
    // property of their sum, not of either alone.
    function test_allocation_is_boot_plus_block() {
        OciVps.applyStatus(makeDocument({
            "storage": {
                "bootSizeGb": 200, "bootVpusPerGb": 10, "bootVpuBillable": false,
                "blockGb": 0, "allocatedGb": 200, "allocationLimitGb": 200,
                "allocationPercent": 100, "allocationFull": true
            }
        }))
        compare(OciVps.allocatedGb, 200)
        compare(OciVps.allocationFull, true)

        OciVps.applyStatus(makeDocument({
            "storage": {
                "bootSizeGb": 50, "bootVpusPerGb": 10, "blockGb": 100,
                "allocatedGb": 150, "allocationLimitGb": 200,
                "allocationPercent": 75, "allocationFull": false
            }
        }))
        compare(OciVps.allocationFull, false)
        compare(OciVps.blockGb, 100)
    }

    function test_egress_series_normalizes_independently() {
        OciVps.applyStatus(makeDocument({
            "dailyEgressGb": [
                { "day": "2026-08-15", "gb": 2 },
                { "day": "2026-08-16", "gb": 8 },
                { "day": "2026-08-17", "gb": 4 }
            ]
        }))
        compare(OciVps.dailyEgressPeak, 8)
        const values = OciVps.dailyEgressNormalized
        compare(values[0], 0.25)
        compare(values[1], 1)
        compare(values[2], 0.5)
    }
}
