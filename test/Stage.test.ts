import { Stage } from '../src/stage';
import { expect } from 'chai';

describe('Stage', () => {
    describe('.find', () => {
        it('returns corresponding stage', () => {
            var stage = Stage.find('test')
            expect(stage).to.instanceof(stage);
        });
    });

    describe('.current', () => {
        it('returns current stage', () => {
            expect(Stage.current).to.instanceof(Stage);
        });
    });
    
});