# Purpose: select implementation experiments without changing camera timing requirements.
# Overview: bounded placement/physical optimization/route choices; all gates stay active.
# Revision: 11-14-2026.
namespace eval rtlnet_camera_impl {}

proc rtlnet_camera_impl::configure {run mode} {
  if {$mode ni {original explore holdfix}} {error "unknown implementation mode $mode"}
  if {$mode eq "original"} {return}
  set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore $run
  set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $run
  if {$mode eq "holdfix"} {
    set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE ExploreWithAggressiveHoldFix $run
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore $run
  } else {
    set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore $run
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore $run
  }
}

proc rtlnet_camera_impl::post_route {mode} {
  if {$mode ni {original explore holdfix}} {error "unknown implementation mode $mode"}
  if {$mode eq "original"} {return}
  if {$mode eq "holdfix"} {
    phys_opt_design -directive ExploreWithAggressiveHoldFix
  } else {
    phys_opt_design -directive ExploreWithHoldFix
  }
}
