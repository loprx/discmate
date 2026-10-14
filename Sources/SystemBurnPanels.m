#import "SystemBurnPanels.h"

DRBurnProgressPanel *DMCreateBurnProgressPanel(void) { return [DRBurnProgressPanel progressPanel]; }
DRBurnSetupPanel *DMCreateBurnSetupPanel(void) { return [DRBurnSetupPanel setupPanel]; }
DREraseProgressPanel *DMCreateEraseProgressPanel(void) { return [DREraseProgressPanel progressPanel]; }
void DMBeginBurnPanel(DRBurnProgressPanel *panel, DRBurn *burn, id layout) {
    [panel beginProgressPanelForBurn:burn layout:layout];
}
void DMBeginErasePanel(DREraseProgressPanel *panel, DRErase *erase) {
    [panel beginProgressPanelForErase:erase];
}
