"""Build the nnU-Net organ network from its checkpoint, trace it on a fixed patch, convert to Core ML."""
import json, sys, time, numpy as np, torch, coremltools as ct
from nnunetv2.utilities.get_network_from_plans import get_network_from_plans
from nnunetv2.utilities.plans_handling.plans_handler import PlansManager

MODEL = '/Users/Sui/.totalsegmentator/nnunet/results/Dataset850_TotalSegMRI_part1_organs_1088subj/nnUNetTrainer_2000epochs_NoMirroring__nnUNetPlans__3d_fullres'
plans = json.load(open(f'{MODEL}/plans.json')); dataset = json.load(open(f'{MODEL}/dataset.json'))
pm = PlansManager(plans); cm = pm.get_configuration('3d_fullres')
n_out = len(dataset['labels'])
net = get_network_from_plans(cm.network_arch_class_name, cm.network_arch_init_kwargs, cm.network_arch_init_kwargs_req_import,
                             1, n_out, allow_init=True, deep_supervision=False)
ck = torch.load(f'{MODEL}/fold_0/checkpoint_final.pth', map_location='cpu', weights_only=False)
net.load_state_dict(ck['network_weights']); net.eval()
patch = cm.patch_size; print('patch', patch, 'classes', n_out)

# Core ML's instance_norm op is rank 3/4 only; nnU-Net's InstanceNorm3d sees rank-5 tensors.
# Swap each one for the same arithmetic written out (mean/var over D,H,W), which converts fine.
class IN3D(torch.nn.Module):
    def __init__(s, m):
        super().__init__(); s.eps = m.eps
        s.w = torch.nn.Parameter(m.weight.detach().clone()); s.b = torch.nn.Parameter(m.bias.detach().clone())
    def forward(s, x):
        mean = x.mean(dim=(2, 3, 4), keepdim=True)
        var = ((x - mean) ** 2).mean(dim=(2, 3, 4), keepdim=True)
        return (x - mean) / torch.sqrt(var + s.eps) * s.w.view(1, -1, 1, 1, 1) + s.b.view(1, -1, 1, 1, 1)
def swap(mod):
    for name, child in mod.named_children():
        if isinstance(child, torch.nn.InstanceNorm3d): setattr(mod, name, IN3D(child))
        else: swap(child)
swap(net); print('instance norms swapped:', sum(isinstance(m, IN3D) for m in net.modules()))

class Wrapped(torch.nn.Module):          # logits only, batch 1
    def __init__(s, n): super().__init__(); s.n = n
    def forward(s, x): return s.n(x)
w = Wrapped(net).eval()
x = torch.randn(1, 1, *patch)
with torch.no_grad():
    # CPU reference (MPS lacks ConvTranspose3d); one forward is a few minutes here.
    t = time.time(); ref = w(x); print('torch fwd', round(time.time() - t, 2), 's', ref.shape)
    traced = torch.jit.trace(w, x, check_trace=False)
t = time.time()
ml = ct.convert(traced, inputs=[ct.TensorType(name='patch', shape=(1, 1, *patch), dtype=np.float32)],
                outputs=[ct.TensorType(name='logits', dtype=np.float16)],
                convert_to='mlprogram', minimum_deployment_target=ct.target.iOS18,
                compute_precision=ct.precision.FLOAT16)
print('converted in', round(time.time() - t), 's')
ml.short_description = 'TotalSegmentator total_mr organs (nnU-Net 3d_fullres, fold 0). Non-commercial licence.'
ml.save(sys.argv[1])
# compare on the same random input
out = ml.predict({'patch': x.numpy()})['logits']
print('coreml out', out.shape, 'max |diff| logits', float(np.abs(out - ref.numpy()).max()),
      'argmax agreement', float((out.argmax(1) == ref.numpy().argmax(1)).mean()))
