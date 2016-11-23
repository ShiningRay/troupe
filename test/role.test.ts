import {Role} from '../src/role'
import * as sinon from 'sinon'
import {assert} from 'chai'
interface IHello {
    world():PromiseLike<any>;
}
describe('Role', () => {
    describe('.define', () => {
        it('defines subclass', () => {
            const role = Role.define<IHello>('Hello', {
                world(){
                    return Promise.resolve('world')
                }
            });
            assert.equal(role, Role.get('Hello'))
        });
    });
});