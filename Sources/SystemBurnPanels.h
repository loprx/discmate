#import <DiscRecordingUI/DiscRecordingUI.h>

// Swift resolves the inherited NSPanel init instead of the NIB-loading factory.
// Keep these documented Objective-C factory calls explicit.
DRBurnProgressPanel * _Nullable DMCreateBurnProgressPanel(void);
DRBurnSetupPanel * _Nullable DMCreateBurnSetupPanel(void);
DREraseProgressPanel * _Nullable DMCreateEraseProgressPanel(void);
void DMBeginBurnPanel(DRBurnProgressPanel * _Nonnull panel, DRBurn * _Nonnull burn,
                      id _Nonnull layout);
void DMBeginErasePanel(DREraseProgressPanel * _Nonnull panel, DRErase * _Nonnull erase);
