import {Stage} from './stage'

class Scenario {
    readonly stage: Stage=Stage.current;
    // router: MessageRouter
    // dispatcher: MessageDispatcher; 
    static readonly current:Scenario = new Scenario();
}
